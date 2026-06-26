# syntax=docker/dockerfile:1

ARG RUBY_VERSION=4.0.2
FROM docker.io/library/ruby:${RUBY_VERSION}-slim

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y bash ca-certificates curl tzdata && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV LANG="C.UTF-8" \
    LC_ALL="C.UTF-8" \
    TZ="America/Toronto" \
    BUNDLE_WITHOUT="test"

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

EXPOSE 8127

CMD ["ruby", "bin/watch"]
