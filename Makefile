.PHONY: build install open dmg dist login-install login-uninstall clean status

build:
	./scripts/build.sh

install:
	./scripts/install-app.sh

open:
	open "$(HOME)/Applications/Clamless.app"

dmg:
	./scripts/package-dmg.sh

dist: dmg

login-install:
	./scripts/install-login-item.sh

login-uninstall:
	./scripts/uninstall-login-item.sh

status:
	.build/clamless-display status

clean:
	rm -rf .build dist
