module DppValidator
  # Settings of one run. Tests shorten the timeouts, trust their own test CA
  # and point the plain-HTTP port of https_redirect at a local server.
  class Config
    attr_accessor :connect_timeout, :read_timeout, :cert_store, :http_port

    def initialize(connect_timeout: 10, read_timeout: 20, cert_store: nil, http_port: 80)
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @cert_store = cert_store || default_cert_store
      @http_port = http_port
    end

    private

    def default_cert_store
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      store
    end
  end
end
