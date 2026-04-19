# Build UI — clone from GitHub

FROM node:16-bullseye AS ui

ARG REACT_REPO_URL
ARG REACT_BRANCH=master

RUN apt-get update -qq && apt-get install -y -qq git

WORKDIR /react

RUN git clone --branch ${REACT_BRANCH} ${REACT_REPO_URL} .

RUN yarn install && PORT=3000 yarn build

# Build backend

FROM ruby:2.6.9-bullseye

WORKDIR /app

EXPOSE 3000

COPY Gemfile Gemfile.lock ./

RUN bundle install

ARG ENVIRONMENT="production"
ENV RAILS_ENV=$ENVIRONMENT

COPY . .

RUN mkdir -p /app/app/assets/builds
COPY --from=ui /react/dist/makerspace-react.js /react/dist/makerspace-react.css /app/app/assets/builds/

# RUN bundle exec rails assets:precompile

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
