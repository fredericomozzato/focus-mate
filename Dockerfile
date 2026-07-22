FROM ruby:4.0.6-bookworm

WORKDIR /app

COPY Gemfile Gemfile.lock ./

RUN bundle install

EXPOSE 3000

CMD ["rails", "server", "-b", "0.0.0.0"]
