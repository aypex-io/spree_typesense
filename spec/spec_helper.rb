require 'bundler/setup'
require 'spree_typesense'

# This gem's specs run standalone (no host Rails app boots the engine's Zeitwerk
# autoloader), so Spree::SearchProvider::Base — which spree_core normally makes
# available via its own engine's autoload paths — never gets defined. Load it
# explicitly, then eager-require this gem's own app/models the same way a real
# host app's autoloader would.
spree_core_root = Gem::Specification.find_by_name('spree_core').gem_dir
require File.join(spree_core_root, 'app/models/spree/search_provider/base')
require File.join(spree_core_root, 'app/presenters/spree/search_provider/product_presenter')

Dir[File.join(__dir__, '..', 'app/models/**/*.rb')].sort.each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.before(:suite) do
    # Fail loudly if no server — mocking a search engine tests nothing useful.
    typesense_client.health.retrieve
  rescue StandardError => e
    abort "Typesense unreachable at #{ENV.fetch('TYPESENSE_URL', 'http://localhost:8108')}: #{e.message}"
  end
end

def typesense_client
  uri = URI.parse(ENV.fetch('TYPESENSE_URL', 'http://localhost:8108'))
  Typesense::Client.new(
    nodes: [{ host: uri.host, port: uri.port, protocol: uri.scheme }],
    api_key: ENV.fetch('TYPESENSE_API_KEY', 'test-key'),
    connection_timeout_seconds: 5
  )
end
