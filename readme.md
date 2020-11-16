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

### Examples

#### Searching with a regular index

First, add an index to the `name` column:

```
> create index name_regular on people (name) ;

CREATE INDEX
Time: 4605.137 ms (00:04.605)
```

Now we can have a look at [the query plan](https://www.postgresql.org/docs/13/using-explain.html).

```
> explain analyse select * from people where name ilike '%gertrude%' limit 15;

                                                         QUERY PLAN
-----------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=1000.00..3574.65 rows=15 width=64) (actual time=7.831..35.360 rows=15 loops=1)
   ->  Gather  (cost=1000.00..52493.00 rows=300 width=64) (actual time=7.830..35.358 rows=15 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         ->  Parallel Seq Scan on people  (cost=0.00..51463.00 rows=125 width=64) (actual time=3.776..25.524 rows=6 loops=3)
               Filter: ((name)::text ~~* '%gertrude%'::text)
               Rows Removed by Filter: 37442
 Planning Time: 0.202 ms
 Execution Time: 35.373 ms
```

Despite an index being present, **PostgreSQL won't use it because we have a wildcard in our search term**. Even if we remove the wildcard prefix (e.g., `like 'gertrude%'`), PostgreSQL would still do a sequential scan 😢

#### Searching with a trigram index

Now, we'll create a [GIN trigram index](https://www.postgresql.org/docs/13/pgtrgm.html#id-1.11.7.40.8) on our `people` table:

```
create index names_trgm on people using gin (name gin_trgm_ops);

CREATE INDEX
Time: 9858.157 ms (00:09.858)
```

And when we re-analyse the same query:

```
> explain analyse select * from people where name ilike '%gertrude%' limit 15;

                                                          QUERY PLAN
------------------------------------------------------------------------------------------------------------------------------
 Limit  (cost=90.33..146.22 rows=15 width=64) (actual time=2.913..2.945 rows=15 loops=1)
   ->  Bitmap Heap Scan on people  (cost=90.33..1208.14 rows=300 width=64) (actual time=2.912..2.942 rows=15 loops=1)
         Recheck Cond: ((name)::text ~~* '%gertrude%'::text)
         Heap Blocks: exact=15
         ->  Bitmap Index Scan on names_trgm  (cost=0.00..90.25 rows=300 width=0) (actual time=2.863..2.863 rows=378 loops=1)
               Index Cond: ((name)::text ~~* '%gertrude%'::text)
 Planning Time: 0.234 ms
 Execution Time: 2.964 ms
```

This time we can see the index is used and the cost is 95% smaller (and ~91% faster). Not bad.
