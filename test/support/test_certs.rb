# A test CA and certificates for localhost and 127.0.0.1, created once per
# test run.
module TestCerts
  module_function

  def ca = @ca ||= build(name: "/CN=dpp-validator test CA", ca: true)
  def store = @store ||= OpenSSL::X509::Store.new.tap { |s| s.add_cert(ca[:cert]) }

  # :trusted (signed by the test CA), :self_signed, :other_host (signed by the
  # test CA for another host name)
  def pair(kind = :trusted)
    @pairs ||= {}
    @pairs[kind] ||= case kind
                     when :trusted then build(name: "/CN=localhost", sans: "DNS:localhost,IP:127.0.0.1", issuer: ca)
                     when :self_signed then build(name: "/CN=localhost", sans: "DNS:localhost,IP:127.0.0.1")
                     when :other_host then build(name: "/CN=example.org", sans: "DNS:example.org", issuer: ca)
                     end
  end

  def build(name:, sans: nil, issuer: nil, ca: false)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1..2**31)
    cert.subject = OpenSSL::X509::Name.parse(name)
    cert.issuer = issuer ? issuer[:cert].subject : cert.subject
    cert.public_key = key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400
    ext = OpenSSL::X509::ExtensionFactory.new
    ext.subject_certificate = cert
    ext.issuer_certificate = issuer ? issuer[:cert] : cert
    if ca
      cert.add_extension(ext.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(ext.create_extension("keyUsage", "keyCertSign,cRLSign", true))
    else
      cert.add_extension(ext.create_extension("basicConstraints", "CA:FALSE", true))
      cert.add_extension(ext.create_extension("subjectAltName", sans)) if sans
    end
    cert.sign(issuer ? issuer[:key] : key, "SHA256")
    { key: key, cert: cert }
  end
end
