class HomeController < ApplicationController
  def index
    @formats = Job.formats
  end
end