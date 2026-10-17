require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test

namespace :funding do
  desc "Write the funding notice from config/funding.yml into the README"
  task :write do
    require_relative "lib/dpp_validator"
    DppValidator::Funding.write!
    puts "written: README.md"
  end
end
