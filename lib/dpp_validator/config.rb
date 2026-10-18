module DppValidator
  # Settings of one run. Tests shorten the timeouts, trust their own test CA
  # and point the plain-HTTP port of https_redirect at a local server.
  # read_only: only GET, HEAD and OPTIONS are sent ("Read-only run" in
  # CRITERIA-FORMAT.md). test_instance: the info of our own test instance the
  # run goes to ("Test instance" in CRITERIA-FORMAT.md), nil otherwise.
  class Config
    attr_accessor :connect_timeout, :read_timeout, :cert_store, :http_port, :read_only, :test_instance

    def initialize(connect_timeout: 10, read_timeout: 20, cert_store: nil, http_port: 80, read_only: false, test_instance: nil)
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @cert_store = cert_store || default_cert_store
      @http_port = http_port
      @read_only = read_only
      @test_instance = test_instance
    end

    private

    def default_cert_store
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      store
    end
  end
end
