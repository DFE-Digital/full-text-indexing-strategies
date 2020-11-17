# Ways of approaching full-text search in PostgreSQL

These examples can be run on a local PostgreSQL database that has a `people` table like this:

```
> create table people ( name varchar(50), address varchar(500) );
```

Experimenting with indexing strategies requires some data. Here's a quick and dirty way to generate some with Ruby.

```ruby
require 'faker'
require 'csv'

Faker::Config.locale = 'en-GB'

rows = 3_000_000.times.map { [Faker::Name.name, Faker::Address.full_address] }

CSV.open("names.csv", "wb") do |csv|
  csv << %w(name address)
  rows.each { |row| csv << row }
end
```

Once you've generated a CSV of fake names you can import it with `psql`:

```
> \copy people from 'names.csv' with csv header;
```
### Regular (`btree`) indexes

When no additional options are provided, PostgreSQL will add a `btree` index by default. When searching for exact strings of text this will be _very fast_, but they can't be utilised for searches against patterns or wildcards.

### Searching with a regular index

```
> create index name_regular on people (name) ;

CREATE INDEX
Time: 4605.137 ms (00:04.605)
```

Now we can have a look at [the query plan](https://www.postgresql.org/docs/13/using-explain.html):

```
explain analyse select name from people where name like '%gertrude%';
                                                       QUERY PLAN
------------------------------------------------------------------------------------------------------------------------
Gather  (cost=1000.00..67980.00 rows=300 width=15) (actual time=129.640..133.378 rows=0 loops=1)
  Workers Planned: 2
  Workers Launched: 2
  ->  Parallel Seq Scan on people  (cost=0.00..66950.00 rows=125 width=15) (actual time=127.475..127.475 rows=0 loops=3)
        Filter: ((name)::text ~~ '%gertrude%'::text)
        Rows Removed by Filter: 1000000
Planning Time: 0.075 ms
Execution Time: 133.395 ms
```

Despite an index being present, **PostgreSQL won't use it because we have a wildcard in our search term**. Even if we remove the wildcard prefix (e.g., `like 'gertrude%'`), PostgreSQL would still do a sequential scan 😢

## [Trigrams](https://www.postgresql.org/docs/13/pgtrgm.html)

> A trigram is a group of three consecutive characters taken from a string. We can measure the similarity of two strings by counting the number of trigrams they share. This simple idea turns out to be very effective for measuring the similarity of words in many natural languages.

To use trigrams you need to enable the `pg_trgm` extension:

```
> create extension pg_trgm;
```

### How the underlying data looks

```
> select show_trgm('The quick brown fox');

                                                 show_trgm
-----------------------------------------------------------------------------------------------------------
{"  b","  f","  q","  t"," br"," fo"," qu"," th",bro,"ck ",fox,"he ",ick,own,"ox ",qui,row,the,uic,"wn "}
```

### Index types

PostgreSQL supports [GiST (lossy) and GIN (lossless) index operators](https://www.postgresql.org/docs/13/textsearch-indexes.html). GIN indexes are the preferred type most of the time as they provide faster lookups than GiST, but GIN indexes are two-to-three times larger, take longer to build and are slower to update.


### Searching with a trigrams

Now, we'll create a [GIN trigram index](https://www.postgresql.org/docs/13/pgtrgm.html#id-1.11.7.40.8) on our `people` table:

```
create index names_trgm on people using gin (name gin_trgm_ops);

CREATE INDEX
Time: 9858.157 ms (00:09.858)
```

And when we re-analyse the same query:

```
explain analyse select name from people where name like '%gertrude%';
                                                      QUERY PLAN
----------------------------------------------------------------------------------------------------------------------
Bitmap Heap Scan on people  (cost=90.33..1225.27 rows=300 width=15) (actual time=3.330..3.330 rows=0 loops=1)
  Recheck Cond: ((name)::text ~~ '%gertrude%'::text)
  Rows Removed by Index Recheck: 355
  Heap Blocks: exact=353
  ->  Bitmap Index Scan on names_trgm  (cost=0.00..90.25 rows=300 width=0) (actual time=2.906..2.906 rows=355 loops=1)
        Index Cond: ((name)::text ~~ '%gertrude%'::text)
Planning Time: 0.093 ms
Execution Time: 3.351 ms
```

This time we can see the _index is used_ and the cost is **98% smaller (and 97.5% faster)**. Not bad.

#### Pros

* easy to set up
* no additional fields or objects necessary
* pretty fast
* can use standard PostgreSQL pattern-matching syntax

#### Cons

* the index (covering only the `name` field) 109MB (the entire table is 409MB)
* inserts will be slightly slower due to index maintenance
* doesn't support the more-advanced [full-text search operators](https://www.postgresql.org/docs/13/textsearch-controls.html#TEXTSEARCH-PARSING-QUERIES)
* no built-in support for [ranking](https://www.postgresql.org/docs/13/textsearch-controls.html#TEXTSEARCH-RANKING) or
  [highlighting](https://www.postgresql.org/docs/13/textsearch-controls.html#TEXTSEARCH-HEADLINE)

## [Lexemes](https://www.postgresql.org/docs/current/textsearch-controls.html)

PostgreSQL allows us to break strings down into a `ts_vector`, which is a hash map containing tokens (lexemes) and the position of the token in the string.

> A lexeme is a unit of lexical meaning that underlies a set of words that are related through inflection. It is a basic abstract unit of meaning, a unit of morphological analysis in linguistics that roughly corresponds to a set of forms taken by a single root word.

### How the underlying data looks

```
> select to_tsvector('The quick brown fox Jumped over the lazy fox');

                  to_tsvector
-----------------------------------------------
'brown':3 'fox':4,9 'jump':5 'lazi':8 'quick':2
```

Things to note about this example:

* `'fox'` has the value `4,9` because the word appears in position `4` and `9` in the original string
* [normalisation](https://www.postgresql.org/docs/13/textsearch-controls.html#TEXTSEARCH-PARSING-DOCUMENTS) has:
  * converted 'lazy' to 'lazi' so that different forms of the same word can be compared (e.g., laziness, laziest)
  * lowercased 'Jumped' and removed the '-ed' suffix
  * removed the extremely-common [stop words](https://en.wikipedia.org/wiki/Stop_word) like 'the' and 'over'


### Searching with lexemes

We need to maintain the `tsvector` for the columns against which we want to search. Generating the vector on the fly is costly and the result cannot be indexed.

If all your columns are in one table it's easiest to add a [generated column](https://www.postgresql.org/docs/13/ddl-generated-columns.html). If you want to search across several tables a [view](https://www.postgresql.org/docs/13/sql-createview.html) (or [materialized view](https://www.postgresql.org/docs/13/sql-creatematerializedview.html) might be a better fit.

First we'll add the generated column.

```
> alter table people
    add column name_tsv tsvector generated always
      as (to_tsvector('english', name)) stored;
```

_Note that if you want to search against multiple columns you can generate the vector using [concatenated columns values](https://www.postgresql.org/docs/13/functions-string.html)_.

Now we can index the vectors:

```
> create index name_gin_tsv on people using gin (name_tsv);

CREATE INDEX
Time: 2297.890 ms (00:02.298)
```

This query is _much faster_:

```
explain analyse select name_tsv from people where name_tsv @@ to_tsquery('Gertrude');
                                                       QUERY PLAN
------------------------------------------------------------------------------------------------------------------------
Bitmap Heap Scan on people  (cost=21.68..2746.28 rows=700 width=37) (actual time=0.116..0.633 rows=683 loops=1)
  Recheck Cond: (name_tsv @@ to_tsquery('Gertrude'::text))
  Heap Blocks: exact=679
  ->  Bitmap Index Scan on name_gin_tsv  (cost=0.00..21.50 rows=700 width=0) (actual time=0.070..0.070 rows=683 loops=1)
        Index Cond: (name_tsv @@ to_tsquery('Gertrude'::text))
Planning Time: 0.114 ms
Execution Time: 0.662 ms
```

Now we're talking. A **96% reduction in cost** and the query runs **99.5% faster** 🔥

#### Pros

* extremely fast
* will match on lexeme, improving search results
* supports [advanced full-text search operators](https://www.postgresql.org/docs/13/textsearch-controls.html#TEXTSEARCH-PARSING-QUERIES)
* the index (covering only the `name` field) is only ~29MB
* built-in support for [ranking](https://www.postgresql.org/docs/13/textsearch-controls.html#TEXTSEARCH-RANKING) and [highlighting](https://www.postgresql.org/docs/13/textsearch-controls.html#TEXTSEARCH-HEADLINE)
* works nicely with [`pg_search`](https://github.com/Casecommons/pg_search)

#### Cons

* extra field (or separate view) required in addition to the index
* inserts will be slightly slower due to index maintenance
* searches for phrases with [stop words](https://www.postgresql.org/docs/13/textsearch-dictionaries.html#TEXTSEARCH-STOPWORDS) won't benefit from indexing
* datatypes aren't supported natively by Rails (you might need to upgrade to `db/schema.sql`)

## Other approaches

These may be covered at some point.

* [Soundex](https://www.postgresql.org/docs/13/fuzzystrmatch.html#id-1.11.7.24.6)
* [Levenshtein](https://www.postgresql.org/docs/13/fuzzystrmatch.html#id-1.11.7.24.7)
* [Metaphone](https://www.postgresql.org/docs/13/fuzzystrmatch.html#id-1.11.7.24.8)
* [Double Metaphone](https://www.postgresql.org/docs/13/fuzzystrmatch.html#id-1.11.7.24.9)
