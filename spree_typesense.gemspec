require_relative 'lib/spree_typesense/version'

Gem::Specification.new do |s|
  s.name        = 'spree_typesense'
  s.version     = SpreeTypesense::VERSION
  s.summary     = 'Typesense search provider for Spree'
  s.authors     = ['Aypex']
  s.files       = Dir['lib/**/*', 'app/**/*']
  s.required_ruby_version = '>= 3.3'

  s.add_dependency 'spree_core', '>= 5.5', '< 6.1'
  s.add_dependency 'typesense', '~> 5.0'

  s.add_development_dependency 'rspec', '~> 3.13'
end
