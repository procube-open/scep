FROM node:18-alpine as node-builder
ENV NODE_OPTIONS --openssl-legacy-provider
# ENV NODE_ENV production
RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app/
COPY ./frontend/package.json ./frontend/package-lock.json ./
RUN npm install
COPY ./frontend/. .
RUN npm run build

FROM golang:alpine
RUN apk update
RUN apk add make
RUN mkdir /download
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . /app
RUN make

COPY --from=node-builder /usr/src/app/build/. ./frontend/build/.
RUN ./scepserver-opt ca -init

CMD ["./scepserver-opt"]
