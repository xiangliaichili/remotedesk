# remotedesk 服务器构建

BIN=remotedesk
LDFLAGS=-s -w

.PHONY: all tidy build run test linux-amd64 linux-arm64 windows-amd64 macos-arm64 clean

all: tidy build

tidy:
	go mod tidy

build:
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(BIN) .

run:
	go run .

test:
	go test ./...

linux-amd64:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(BIN)-linux-amd64 .

linux-arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(BIN)-linux-arm64 .

windows-amd64:
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(BIN)-windows-amd64.exe .

macos-arm64:
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(BIN)-macos-arm64 .

clean:
	rm -rf bin
