require 'spec_helper'

RSpec.describe SpreeTypesense do
  it 'has a version' do
    expect(SpreeTypesense::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it 'can reach the Typesense server' do
    expect(typesense_client.health.retrieve).to include('ok' => true)
  end
end
