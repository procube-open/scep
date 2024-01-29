FROM golang:alpine as go-build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . /app
RUN go build -o main ./cmd/scepserver

FROM alpine:3
RUN mkdir /app
WORKDIR /app
COPY --from=go-build /app/main ./main
RUN ./main ca -init
CMD ["./main"]
