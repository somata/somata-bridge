build:
	# Compile .coffee to .js
	coffee -o lib -c src

	# Ugly hack to prepend shebang line
	cp lib/bridge.js lib/bridge.js.tmp
	echo "#!/usr/bin/env node" > lib/bridge.js.tmp
	cat lib/bridge.js >> lib/bridge.js.tmp
	mv lib/bridge.js.tmp lib/bridge.js

