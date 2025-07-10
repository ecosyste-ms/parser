Faraday.default_adapter = :net_http_persistent
Faraday.default_connection_options = {
  headers: {
    'User-Agent' => 'parser.ecosyste.ms'
  }
}