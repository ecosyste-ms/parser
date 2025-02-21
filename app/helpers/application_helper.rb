module ApplicationHelper
  def meta_title
    [@meta_title, 'Ecosyste.ms: Parser'].compact.join(' | ')
  end

  def meta_description
    @meta_description || app_description
  end

  def app_name
    "Parser"
  end

  def app_description
    "An open API service to parse dependency metadata from many open source software ecosystems manifest files."
  end
end
