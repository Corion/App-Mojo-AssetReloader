# Mojo Asset Live Reloader

![Demo movie of live reloading](https://github.com/Corion/App-Mojo-AssetReloader/raw/master/demo/hero-demo.gif)

Written using [Mojolicious](http:s//mojolicious.org)

* [x] Reloads your (static) HTML
* [x] Reloads your CSS if it changes
* [x] Reloads your images if they change

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
* [ ] Allow specifying your own Javascript to include
* [ ] Add `system` action to configuration to (re)launch `make` or `jekyll`

# Done

* [x] Read methods from a config file
