# ubuntu-lite: make keys | build | test | clean
.PHONY: keys build resume test test-boot clean docker-build
keys:
	build/keys.sh
build:
	sudo -E build/build.sh
resume:
	sudo -E build/build.sh --from $(FROM)
test:
	scripts/test-qemu.sh install
test-boot:
	scripts/test-qemu.sh boot
clean:
	sudo rm -rf out/work out/*.iso out/*.sha256
docker-build:
	docker build -t ubuntu-lite-builder build/
	docker run --rm --privileged -v $(CURDIR):/src -v /var/run/docker.sock:/var/run/docker.sock ubuntu-lite-builder build/build.sh
