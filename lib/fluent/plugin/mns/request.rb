require 'uri'
require 'rexml/document'

module Fluent
  module Plugin
    module MNS
      # Class for Aliyun MNS Request.
      class Request
        include REXML

        attr_reader :log, :uri, :method, :body, :content_md5, :content_type,
                    :content_length, :mns_headers, :access_key_id,
                    :access_key_secret, :endpoint

        def initialize(opts, headers, params)
          @log = opts[:log]
          conf = {
            host: opts[:endpoint],
            path: opts[:path]
          }

          conf[:query] = URI.encode_www_form(params) unless params.empty?
          @uri = URI::HTTP.build(conf)
          @method = opts[:method].to_s.downcase
          @mns_headers = headers.merge('x-mns-version' => '2015-06-06')
          @access_key_id = opts[:access_key_id]
          @access_key_secret = opts[:access_key_secret]

          log.info uri.to_s
        end

        def content(type, values = {})
          ns = 'http://mns.aliyuncs.com/doc/v1/'
          builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
            xml.send(type.to_sym, xmlns: ns) do |b|
              values.each { |k, v| b.send k.to_sym, v }
            end
          end
          @body = builder.to_xml
          @content_md5 = Base64.encode64(Digest::MD5.hexdigest(body)).chop
          @content_length = body.size
          @content_type = 'text/xml;charset=utf-8'
        end

        def execute
          date = DateTime.now.httpdate
          headers = {
            'Authorization' => authorization(date),
            'Content-Length' => content_length || 0,
            'Content-Type' => content_type,
            'Content-MD5' => content_md5,
            'Date' => date,
            'Host' => uri.host
          }.merge(@mns_headers).reject { |k, v| v.nil? }

          begin
            RestClient.send *[method, uri.to_s, headers, body].compact
          rescue RestClient::Exception => e
            doc = Document.new(e.response.to_s)
            doc.elements[1].each do |e|
              next unless e.node_type == :element
              return nil if (e.name == 'Code') && (e.text == 'MessageNotExist')
            end

            log.error e.response

            raise e
          end
        end

        def authorization(date)
          canonical_resource = [uri.path, uri.query].compact.join('?')
          canonical_headers = mns_headers.sort.collect { |k, v| "#{k.downcase}:#{v}" }.join("\n")
          signature = [method.to_s.upcase, content_md5 || '', content_type || '', date, canonical_headers, canonical_resource].join("\n")
          sha1 = OpenSSL::HMAC.digest('sha1', access_key_secret, signature)
          "MNS #{access_key_id}:#{Base64.encode64(sha1).chop}"
        end
      end
    end
  end
end