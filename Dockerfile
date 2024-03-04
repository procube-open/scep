FROM node:18-alpine as node-builder
ENV NODE_OPTIONS --openssl-legacy-provider
# ENV NODE_ENV production
RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app/
COPY ./frontend/package.json ./frontend/package-lock.json ./
RUN npm install
COPY ./frontend/. .
RUN npm run build

FROM golang:alpine as go-builder
RUN apk update
RUN apk add make
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . /app
RUN make

ARG SERVER_URL="http://127.0.0.1:2016/scep"
ARG PKEY_FILENAME="key.pem"
ARG CERT_FILENAME="cert.pem"
ARG KEY_SIZE="2048"
ENV SCEPCL_KEYSIZE=${KEY_SIZE}
ARG ORG=""
ENV SCEPCL_ORG=${ORG}
ARG OU=""
ENV SCEPCL_OU=${OU}
ARG COUNTRY="JP"
ENV SCEPCL_COUNTRY=${COUNTRY}

RUN GOOS=linux GOARCH=amd64 \
  go build -ldflags "\
  -X main.flServerURL=${SERVER_URL} \
  -X main.flPKeyFileName=${PKEY_FILENAME} \
  -X main.flCertFileName=${CERT_FILENAME} \
  -X main.flKeySize=${KEY_SIZE} \
  -X main.flORG=${ORG} \
  -X main.flOU=${OU} \
  -X main.flCountry=${COUNTRY}\
  " -o scepclient-amd64 ./cmd/scepclient
RUN GOOS=linux GOARCH=arm \
  go build -ldflags "\
  -X main.flServerURL=${SERVER_URL} \
  -X main.flPKeyFileName=${PKEY_FILENAME} \
  -X main.flCertFileName=${CERT_FILENAME} \
  -X main.flKeySize=${KEY_SIZE} \
  -X main.flORG=${ORG} \
  -X main.flOU=${OU} \
  -X main.flCountry=${COUNTRY}\
  " -o scepclient-arm ./cmd/scepclient
RUN GOOS=linux GOARCH=arm64 \
  go build -ldflags "\
  -X main.flServerURL=${SERVER_URL} \
  -X main.flPKeyFileName=${PKEY_FILENAME} \
  -X main.flCertFileName=${CERT_FILENAME} \
  -X main.flKeySize=${KEY_SIZE} \
  -X main.flORG=${ORG} \
  -X main.flOU=${OU} \
  -X main.flCountry=${COUNTRY}\
  " -o scepclient-arm64 ./cmd/scepclient

FROM alpine:3
RUN mkdir /app
RUN mkdir /client

WORKDIR /client
COPY --from=go-builder /app/scepclient-amd64 ./
COPY --from=go-builder /app/scepclient-arm ./
COPY --from=go-builder /app/scepclient-arm64 ./

WORKDIR /app
COPY --from=go-builder /app/scepserver-opt /app/scepclient-opt ./
COPY --from=node-builder /usr/src/app/build/. ./frontend/.
RUN ./scepserver-opt ca -init

CMD ["./scepserver-opt"]
