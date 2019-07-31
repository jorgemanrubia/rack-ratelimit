require 'rubygems'
require 'bundler/setup'
require 'rake'
require 'rake/testtask'

task :default => :test

Rake::TestTask.new do |t|
  t.test_files = Dir['test/*_test.rb'].reject do |path|
    (path =~ /system/ unless ENV['SYSTEM_TESTS']) ||
        (path =~ /performance/ unless ENV['PERFORMANCE_TESTS'])
  end
end

namespace :test do
  Rake::TestTask.new(:system) do |t|
    t.pattern = 'test/*_system_test.rb'
  end

  Rake::TestTask.new(:performance) do |t|
    t.pattern = 'test/*_performance_test.rb'
  end
end
