require 'bundler/setup'
require 'spree_typesense'

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
