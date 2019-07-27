require 'sinatra/base' # 'modular' style

class DummyApp < Sinatra::Base
  get '/protected' do
    "A rate limited endpoint"
  end

  get '/open' do
    "A regular endpoint"
  end
end
