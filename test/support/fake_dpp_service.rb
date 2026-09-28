# A DPP service for end-to-end tests that behaves as the service criteria of
# dpp-criteria expect: HTTP/2 only, EN 18222 read methods, 400 for malformed
# requests, 401 for writes without credentials.
module FakeDppService
  module_function

  def passport(dpp_id, product_id)
    { "digitalProductPassportId" => dpp_id, "uniqueProductIdentifier" => product_id, "dppStatus" => "Active",
      "ProductIdentification" => { "ModelIdentifier" => "M-1" } }
  end

  def handler(dpp_id, product_id)
    enc = ->(v) { DppValidator::Placeholders.percent_encode(v) }
    body = JSON.generate(passport(dpp_id, product_id))
    json = ->(status, value) { [status, { "Content-Type" => "application/json" }, value.is_a?(String) ? value : JSON.generate(value)] }
    lambda do |r|
      path, query = r.path.split("?", 2)
      case [r.method, path]
      in ["GET", p] if p == "/dpp/v1/dpps/#{enc.(dpp_id)}" then json.(200, body)
      in ["GET", p] if p == "/dpp/v1/dppsByProductId/#{enc.(product_id)}" then json.(200, body)
      in ["GET", p] if p == "/dpp/v1/dppsByIdAndDate/#{enc.(dpp_id)}" && query.to_s.start_with?("date=") then json.(200, body)
      in ["GET", p] if p == "/dpp/v1/dpps/#{enc.(dpp_id)}/elements/%24.ProductIdentification.ModelIdentifier" then json.(200, "\"M-1\"")
      in ["GET", p] if p.start_with?("/dpp/v1/dpps/#{enc.(dpp_id)}/elements/") then json.(400, { "message" => "invalid elementIdPath" })
      in ["POST", "/dpp/v1/dppsByProductIds"]
        list = JSON.parse(r.body) rescue nil
        list.is_a?(Array) ? json.(200, { "dppIds" => [dpp_id] }) : json.(400, { "message" => "bad request" })
      in ["PATCH" | "POST", _] then json.(401, { "message" => "unauthorised" })
      else json.(404, { "message" => "not found" })
      end
    end
  end
end
