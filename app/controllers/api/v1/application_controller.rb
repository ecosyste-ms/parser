class Api::V1::ApplicationController < ApplicationController
  skip_before_action :verify_authenticity_token
  after_action { pagy_headers_merge(@pagy) if @pagy }
end