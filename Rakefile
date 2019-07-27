require 'rubygems'
require 'bundler/setup'
require 'rake'
require 'rake/testtask'

task :default => :test

Rake::TestTask.new do |t|
  t.test_files = Dir['test/*_test.rb'].reject do |path|
    path =~ /system/ unless ENV['SYSTEM_TESTS']
  end
end
