# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = 'aws-tasks'
  s.version     = File.read(File.expand_path('../VERSION', __FILE__)).strip
  s.summary     = 'AWS helper tasks'
  s.description = 'AWS helper tasks for DB and such'
  s.homepage    = 'http://github.com/attribution/aws-tasks'
  s.licenses    = ['MIT']
  s.authors     = ['Sam Reh']
  s.email       = ['samuelreh@gmail.com']

  s.require_paths = ['lib']
  s.files = [
    'LICENSE.txt',
    'VERSION',
    'aws-tasks.gemspec',
    'lib/aws-tasks.rb',
    'lib/aws-tasks/security_group.rb',
    'lib/aws-tasks/vpc_prefix_list.rb',
    'lib/aws-tasks/tasks/rds.rake',
    'lib/aws-tasks/tasks/redshift.rake'
  ]

  s.add_dependency 'aws-sdk-ec2', '~> 1'
  s.add_dependency 'aws-sdk-rds', '~> 1'
  s.add_dependency 'aws-sdk-redshift', '~> 1'
end
