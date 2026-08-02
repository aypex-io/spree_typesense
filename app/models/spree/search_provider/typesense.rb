module Spree
  module SearchProvider
    class Typesense < Base
      def self.indexing_required?
        true
      end

      def ensure_index_settings!
        client.collections.create(Schema.definition(collection_name))
      rescue ::Typesense::Error::ObjectAlreadyExists
        nil
      end

      def index(product)
        docs = Array(presenter_class.new(product, store).as_documents)
        index_batch(docs)
      end

      def index_batch(documents)
        return if documents.blank?

        client.collections[collection_name]
              .documents
              .import(documents, action: 'upsert')
      end

      def remove(product)
        remove_by_id(product.prefixed_id)
      end

      # Composite ids mean one product maps to N documents (locale × currency),
      # so delete by filter on product_id rather than by document id.
      def remove_by_id(prefixed_id)
        client.collections[collection_name]
              .documents
              .delete(filter_by: "product_id:=#{prefixed_id}")
      rescue ::Typesense::Error::ObjectNotFound
        nil
      end

      def client
        @client ||= begin
          uri = URI.parse(ENV.fetch('TYPESENSE_URL'))
          ::Typesense::Client.new(
            nodes: [{ host: uri.host, port: uri.port, protocol: uri.scheme }],
            api_key: ENV.fetch('TYPESENSE_API_KEY'),
            connection_timeout_seconds: 5
          )
        end
      end

      def collection_name
        @collection_name ||= "products_#{store.code}"
      end

      private

      def presenter_class
        Spree::SearchProvider::ProductPresenter
      end
    end
  end
end
