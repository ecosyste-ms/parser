FROM golang:1.27-alpine AS parser

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -o /manifest-parser ./cmd/manifest-parser

FROM ruby:4.0.7-alpine

COPY --from=parser /manifest-parser /usr/local/bin/manifest-parser
ENV MANIFEST_PARSER_COMMAND=/usr/local/bin/manifest-parser

ENV APP_ROOT=/usr/src/app
ENV DATABASE_PORT=5432
WORKDIR $APP_ROOT

# =============================================
# System layer

# Will invalidate cache as soon as the Gemfile changes
COPY Gemfile Gemfile.lock $APP_ROOT/

# * Setup system
# * Install Ruby dependencies
RUN apk add --update \
    build-base \
    netcat-openbsd \
    git \
    nodejs \
    postgresql-dev \
    tzdata \
    curl-dev \
    libc6-compat \
    yaml-dev \
    libffi-dev \
    bash \
    jemalloc \
 && rm -rf /var/cache/apk/* \
 && gem update --system \
 && gem install bundler foreman \
 && bundle config --global frozen 1 \
 && bundle config set without 'test' \
 && bundle install --jobs 2

ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2
ENV RUBY_YJIT_ENABLE=1

# ========================================================
# Application layer

# Copy application code
COPY . $APP_ROOT

# Precompile assets for a production environment.
# This is done to include assets in production images on Dockerhub.
RUN RAILS_ENV=production bundle exec rake assets:precompile

# Startup
CMD ["bin/docker-start"]
