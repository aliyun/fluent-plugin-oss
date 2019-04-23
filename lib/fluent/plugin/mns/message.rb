require 'rexml/document'

module Fluent
  module Plugin
    module MNS
      # Class for Aliyun MNS Message.
      class Message
        include REXML

        attr_reader :queue, :id, :body_md5, :body, :receipt_handle, :enqueue_at,
                    :first_enqueue_at, :next_visible_at, :dequeue_count, :priority

        def initialize(queue, content)
          @queue = queue

          doc = Document.new(content)
          doc.elements[1].each do |e|
            if e.node_type == :element
              if e.name == 'MessageId'
                @id = e.text
              elsif e.name == 'MessageBodyMD5'
                @body_md5 = e.text
              elsif e.name == 'MessageBody'
                @body = e.text
              elsif e.name == 'EnqueueTime'
                @enqueue_at = e.text.to_i
              elsif e.name == 'FirstDequeueTime'
                @first_enqueue_at = e.text.to_i
              elsif e.name == 'DequeueCount'
                @dequeue_count = e.text.to_i
              elsif e.name == 'Priority'
                @priority = e.text.to_i
              elsif e.name == 'ReceiptHandle'
                @receipt_handle = e.text
              elsif e.name == 'NextVisibleTime'
                @next_visible_at = e.text.to_i
              end
            end
          end

          # verify body
          md5 = Digest::MD5.hexdigest(body).upcase
          unless md5 == body_md5
            raise Exception,
                  'Invalid MNS Body, MD5 does not match, '\
                  "MD5 #{body_md5}, expect MD5 #{md5}, Body: #{body}"
          end
        end
      end
    end
  end
end
