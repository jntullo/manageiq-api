module Api
  class RequestConfiguration
    attr_reader :request, :collection_config

    def initialize(request, collection_config)
      @request = request
      @collection_config = collection_config
    end

    def request_collection_config
      @request_collection_config ||= collection_config[request.collection]
    end

    def collection_name
      @collection_name ||= if request.collection && arbitrary_resource_path?
                             request.collection
                           else
                             request.subject
                           end
    end

    def arbitrary_resource_path?
      @arbitrary ||= request_collection_config&.options&.include?(:arbitrary_resource_path)
    end

    def primary_collection?
      @primary_collection ||= collection_config.primary?(collection_name)
    end

    def subcollection
      @subcollection ||= request.subcollection
    end

    def aspec
      @aspec ||= if request.subcollection
                   collection_config.typed_subcollection_actions(request.collection, collection_name, target) || collection_config.typed_collection_actions(collection_name, target)
                 else
                   collection_config.typed_collection_actions(collection_name, target)
                 end
    end

    def action_hash
      Array(aspec[@request.method]).detect { |h| h[:name] == @request.action } || {}
    end

    def type
      @type ||= if (request.collection_id && !request.subcollection) || (request.subcollection && request.subcollection_id)
                  :resource
                else
                  :collection
                end
    end

    def target
      @target ||= if request.subcollection && !request_collection_config.options&.include?(:arbitrary_resource_path)
                    request.subcollection_id ? :subresource : :subcollection
                  else
                    request.collection_id ? :resource : :collection
                  end
    end
  end
end
