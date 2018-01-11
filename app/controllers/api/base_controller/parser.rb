module Api
  class BaseController
    module Parser
      def parse_api_request
        @req = RequestAdapter.new(request, params)
        @configuration = RequestConfiguration.new(@req, collection_config)
      end

      def validate_api_request
        validate_optional_collection_classes

        # API Version Validation
        if @req.version
          vname = @req.version
          unless Api::SUPPORTED_VERSIONS.include?(vname)
            raise BadRequestError, "Unsupported API Version #{vname} specified"
          end
        end

        validate_api_request_collection if @req.collection
        validate_api_request_subcollection

        # Method Validation for the collection or sub-collection specified
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
        return validate_post_method if @req.method == :post
        action_hash = @configuration.action_hash
        raise BadRequestError, "Disabled action #{@req.action}" if action_hash[:disabled]
        unless api_user_role_allows?(action_hash[:identifier])
          raise ForbiddenError, "Use of the #{@req.action} action is forbidden"
        end
      end

      def parse_id(resource, collection)
        return nil if !resource.kind_of?(Hash) || resource.blank?

        href_id = href_id(resource["href"], collection)
        case
        when href_id.present?
          href_id
        when resource["id"].kind_of?(Integer)
          resource["id"]
        when resource["id"].kind_of?(String)
          resource["id"].to_i
        end
      end

      def href_id(href, collection)
        if href.present? && href.match(%r{^.*/#{collection}/(\d+)$})
          Regexp.last_match(1).to_i
        end
      end

      def parse_by_attr(resource, type, attr_list = [])
        klass = collection_class(type)
        attr_list |= %w(guid) if klass.attribute_method?(:guid)
        attr_list |= String(collection_config[type].identifying_attrs).split(",")
        objs = attr_list.map { |attr| klass.find_by(attr => resource[attr]) if resource[attr] }.compact
        objs.collect(&:id).first
      end

      def parse_owner(resource)
        return nil if resource.blank?
        parse_id(resource, :users) || parse_by_attr(resource, :users)
      end

      def parse_group(resource)
        return nil if resource.blank?
        parse_id(resource, :groups) || parse_by_attr(resource, :groups)
      end

      def parse_role(resource)
        return nil if resource.blank?
        parse_id(resource, :roles) || parse_by_attr(resource, :roles)
      end

      def parse_tenant(resource)
        parse_id(resource, :tenants) unless resource.blank?
      end

      def parse_ownership(data)
        {
          :owner => collection_class(:users).find_by(:id => parse_owner(data["owner"])),
          :group => collection_class(:groups).find_by(:id => parse_group(data["group"]))
        }.compact if data.present?
      end

      # RBAC Aware type specific resource fetches

      def parse_fetch_group(data)
        if data
          group_id = parse_group(data)
          raise BadRequestError, "Missing Group identifier href, id or description" if group_id.nil?
          resource_search(group_id, :groups, collection_class(:groups))
        end
      end

      def parse_fetch_role(data)
        if data
          role_id = parse_role(data)
          raise BadRequestError, "Missing Role identifier href, id or name" if role_id.nil?
          resource_search(role_id, :roles, collection_class(:roles))
        end
      end

      def parse_fetch_tenant(data)
        if data
          tenant_id = parse_tenant(data)
          raise BadRequestError, "Missing Tenant identifier href or id" if tenant_id.nil?
          resource_search(tenant_id, :tenants, collection_class(:tenants))
        end
      end

      private

      #
      # For Posts we need to support actions, let's validate those
      #
      def validate_post_method
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

        validate_post_api_action_as_subcollection(@configuration.collection_name, @req.method, @req.action)
      end

      def validate_api_request_collection
        # Collection Validation
        cname = @req.collection
        raise BadRequestError, "Unsupported Collection #{cname} specified" unless collection_config[cname]
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

      def validate_post_api_action_as_subcollection(cname, mname, aname)
        return if cname == @req.collection
        return if collection_config.subcollection_denied?(@req.collection, cname)

        aspec = collection_config.typed_subcollection_actions(@req.collection, cname, @req.subcollection_id ? :subresource : :subcollection)
        return unless aspec

        action_hash = @configuration.action_hash
        raise BadRequestError, "Unsupported Action #{aname} for the #{cname} sub-collection" if action_hash.blank?
        raise BadRequestError, "Disabled Action #{aname} for the #{cname} sub-collection" if action_hash[:disabled]

        unless api_user_role_allows?(action_hash[:identifier])
          raise ForbiddenError, "Use of Action #{aname} for the #{cname} sub-collection is forbidden"
        end
      end

      def collection_option?(option)
        collection_config.option?(@req.collection, option) if @req.collection
      end

      def assert_id_not_specified(data, type)
        if data.key?('id') || data.key?('href')
          raise BadRequestError, "Resource id or href should not be specified for creating a new #{type}"
        end
      end

      def assert_all_required_fields_exists(data, type, required_fields)
        missing_fields = required_fields - data.keys
        unless missing_fields.empty?
          raise BadRequestError, "Resource #{missing_fields.join(", ")} needs be specified for creating a new #{type}"
        end
      end
    end
  end
end
