module Api
  class BaseController
    module Validator
      def validate_api_version
        if @req.version
          vname = @req.version
          unless Api::SUPPORTED_VERSIONS.include?(vname)
            raise BadRequestError, "Unsupported API Version #{vname} specified"
          end
        end
      end

      def validate_request_method
        if @configuration.collection_name && @configuration.type
          unless collection_config.supports_http_method?(@configuration.collection_name, @req.method) || @req.method == :options
            raise BadRequestError, "Unsupported HTTP Method #{@req.method} for the #{@configuration.type} #{@configuration.collection_name} specified"
          end
        end
      end

      def validate_optional_collection_classes
        @collection_klasses = {} # Default all to config classes
        param = params['collection_class']
        return unless param.present?

        klass = collection_class(@req.collection)
        return if param == klass.name

        param_klass = klass.descendants.detect { |sub_klass| param == sub_klass.name }
        if param_klass.present?
          @collection_klasses[@req.collection.to_sym] = param_klass
          return
        end

        raise BadRequestError, "Invalid collection_class #{param} specified for the #{@req.collection} collection"
      end

      def validate_api_action
        return unless @req.collection
        return if @req.method == :get && @configuration.aspec.nil?
        action_hash = @configuration.action_hash
        raise BadRequestError, "Disabled action #{@req.action}" if action_hash[:disabled]
        unless api_user_role_allows?(action_hash[:identifier])
          raise ForbiddenError, "Use of the #{@req.action} action is forbidden"
        end
      end

      def validate_post_method
        return unless @req.method == :post
        raise BadRequestError, "No actions are supported for #{@configuration} #{@configuration.type}" unless @configuration.aspec

        if @configuration.action_hash.blank?
          unless @configuration.type == :resource && @configuration.request_collection_config&.options&.include?(:custom_actions)
            raise BadRequestError, "Unsupported Action #{@req.action} for the #{@configuration.collection_name} #{@configuration.type} specified"
          end
        end

        if @configuration.action_hash.present?
          raise BadRequestError, "Disabled Action #{@req.action} for the #{@configuration.collection_name} #{@configuration.type} specified" if @configuration.action_hash[:disabled]
          unless api_user_role_allows?(@configuration.action_hash[:identifier])
            raise ForbiddenError, "Use of Action #{@req.action} is forbidden"
          end
        end

        validate_post_api_action_as_subcollection
      end

      def validate_api_request_collection
        cname = @req.collection
        return unless cname
        raise BadRequestError, "Unsupported Collection #{@req.collection} specified" unless collection_config[cname]
        if collection_config.primary?(cname)
          if "#{@req.collection_id}#{@req.subcollection}#{@req.subcollection_id}".present?
            raise BadRequestError, "Invalid request for Collection #{cname} specified"
          end
        else
          raise BadRequestError, "Unsupported Collection #{cname} specified" unless collection_config.collection?(cname)
        end
      end

      def validate_api_request_subcollection
        # Sub-Collection Validation for the specified Collection
        if @req.collection && @req.subcollection && !@configuration.arbitrary_resource_path?
          unless collection_config.subcollection?(@req.collection, @req.subcollection)
            raise BadRequestError, "Unsupported Sub-Collection #{@req.subcollection} specified"
          end
        end
      end

      def validate_post_api_action_as_subcollection
        return if @configuration.collection_name == @req.collection
        return if collection_config.subcollection_denied?(@req.collection, @configuration.collection_name)
        return unless @configuration.aspec

        aname = @req.action
        action_hash = @configuration.action_hash
        raise BadRequestError, "Unsupported Action #{aname} for the #{@configuration.collection_name} sub-collection" if action_hash.blank?
        raise BadRequestError, "Disabled Action #{aname} for the #{@configuration.collection_name} sub-collection" if action_hash[:disabled]

        unless api_user_role_allows?(action_hash[:identifier])
          raise ForbiddenError, "Use of Action #{aname} for the #{@configuration.collection_name} sub-collection is forbidden"
        end
      end
    end
  end
end
