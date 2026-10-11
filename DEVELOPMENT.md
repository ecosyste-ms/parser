# Development

## Setup

First things first, you'll need to fork and clone the repository to your local machine.

`git clone https://github.com/ecosyste-ms/parser.git`

The project uses ruby on rails which have a number of system dependencies you'll need to install.

- [ruby](https://www.ruby-lang.org/en/documentation/installation/)
- [postgresql 14](https://www.postgresql.org/download/)
- [redis 6+](https://redis.io/download/)
- [node.js 16+](https://nodejs.org/en/download/)
- Go, using the minimum version in `go.mod`

You will then need to set some configuration environment variables. Copy `env.example` to `.env.development` and customise the values to suit your local setup.

Once you've got all of those installed, from the root directory of the project run the following commands:

```
bin/setup
bin/dev
```

`bin/setup` builds the Go parser into `tmp/manifest-parser`. After changing its Go source, rebuild it with:

```
go build -mod=readonly -o tmp/manifest-parser ./cmd/manifest-parser
```

Set `MANIFEST_PARSER_COMMAND` to use a binary at another path. Docker builds and installs the command automatically.

You can then load up [http://localhost:3000](http://localhost:3000) to access the service.

### Docker

Alternatively you can use the existing docker configuration files to run the app in a container.

Run this command from the root directory of the project to start the service.

`docker-compose up --build`

You can then load up [http://localhost:3000](http://localhost:3000) to access the service.

For access the rails console use the following command:

`docker-compose exec app rails console`

## Tests

The applications tests can be found in [test](test) and use the testing framework [minitest](https://github.com/minitest/minitest).

You can run all the tests with:

```
go test -mod=readonly ./...
go build -mod=readonly -o tmp/manifest-parser ./cmd/manifest-parser
rails test
```

The Rails integration tests invoke the compiled command. `-mod=readonly` prevents Go from treating the Rails `vendor` directory as vendored Go dependencies.

To inspect the command's JSON output directly:

```
tmp/manifest-parser -strip-components 1 test/fixtures/files/main.zip
tmp/manifest-parser Gemfile
```

The v1 adapter keeps the existing ecosystem names and response fields, including `go.sum` as a lockfile. Archive paths retain v1's removal of the first path component. Dependency scopes and supported formats come from the Go parser; unsupported formats are omitted from the advertised list. npm workspace-link metadata depends on the upstream fix in [manifests issue 114](https://github.com/git-pkgs/manifests/issues/114).

## Background tasks

Background tasks are handled by [sidekiq](https://github.com/mperham/sidekiq), the workers live in [app/sidekiq](app/sidekiq/).

Sidekiq is automatically run by `bin/dev`, but if you need to run it manually, run the following command:

`bundle exec sidekiq`

You can also view the status of the workers and their queues from the web interface http://localhost:3000/sidekiq

## Deployment

A container-based deployment is highly recommended, we use [dokku.com](https://dokku.com/).
