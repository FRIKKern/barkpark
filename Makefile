.PHONY: run build clean

run:
	go run .

build:
	go build -o sanity-tui .

clean:
	rm -f sanity-tui
