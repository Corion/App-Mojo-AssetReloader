# Mojo Asset Live Reloader

![Demo movie of live reloading](https://github.com/Corion/App-Mojo-AssetReloader/raw/master/demo/hero-demo.gif)

Written using [Mojolicious](http:s//mojolicious.org)

* [x] Reloads your (static) HTML
* [x] Reloads your CSS if it changes
* [x] Reloads your images if they change
* [x] Regenerates your assets from source files

# Installation

    git clone https://github.com/Corion/App-Mojo-AssetReloader
    cd App-Mojo-AssetReloader
    cpan .

# Usage

    mojo-assetreloader.pl daemon demo/

Then visit [http://localhost:3000](http://localhost:3000) or whatever other URL
the console output displays.

# To be implemented

* [ ] Demo of two differently sized browser windows side-by-side
* [ ] Move hot-reloaded Javascript to a separate file
* [ ] Watch hot-reloaded Javascript
* [ ] Pass a "server launched at" timestamp to the client so the client knows
      when it needs a full resync if the server restarts
      ... or simply reload the HTML/page on reconnection?!
* [ ] Can we make the HTML rewriting more optional?

# Done

* [x] Read methods from a config file
* [x] Add `run` action to configuration to (re)launch `make` or `jekyll`
* [x] Allow specifying your own Javascript to include
* [x] Implement a tag for JS insertion so we can also reload the page when
      the templates get rewritten, like Mojolicious::Plugin::AutoReload does.
