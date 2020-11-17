require 'faker'
require 'csv'

Faker::Config.locale = 'en-GB'

rows = 3_000_000.times.map { [Faker::Name.name, Faker::Address.full_address] }

CSV.open("names.csv", "wb") do |csv|
  csv << %w(name address)
  rows.each { |row| csv << row }
end
