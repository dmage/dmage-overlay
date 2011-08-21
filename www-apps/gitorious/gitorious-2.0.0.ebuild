# Copyright 1999-2011 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI=4
USE_RUBY="ruby18"
inherit eutils confutils depend.apache ruby-ng

DESCRIPTION="Gitorious"
HOMEPAGE="http://gitorious.org/gitorious/"
SRC_URI="http://gitorious.org/${PN}/mainline/archive-tarball/v${PV} -> ${P}.tar.gz"

LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64"
IUSE="ssl"

DEPEND="sys-apps/findutils"
#RDEPEND="${DEPEND}"
RDEPEND="$(ruby_implementation_depend ruby18)
	www-apache/passenger
	app-misc/sphinx
	net-misc/memcached"

ruby_add_rdepend "dev-ruby/rake
	dev-ruby/bundler
	dev-ruby/stompserver"

RUBY_S="${PN}-mainline"

GITORIOUS_DIR="/var/lib/${PN}"
GIT_USER="git"
GIT_GROUP="git"

pkg_setup() {
	#confutils_require_any mysql postgres sqlite3
	enewgroup "${GIT_GROUP}"
	###### copy from redmine: home directory is required for SCM.
	enewuser "${GIT_USER}" -1 /bin/bash "${GITORIOUS_DIR}" "${GIT_GROUP},cron"
}

all_ruby_prepare() {
	rm -r log || die
	#rm -rf vendor/rails || die
	echo "CONFIG_PROTECT=\"${EPREFIX}${GITORIOUS_DIR}/config\"" > "${T}/50${PN}"
	#echo "CONFIG_PROTECT_MASK=\"${EPREFIX}${REDMINE_DIR}/config/locales ${EPREFIX}${REDMINE_DIR}/config/settings.yml\"" >> "${T}/50${PN}"
}

all_ruby_install() {
	dodoc doc/{README,README_FOR_APP,WISHLIST}
	rm -rf doc || die

	keepdir /var/log/${PN}
	dosym ../../log/${PN}/ "${GITORIOUS_DIR}/log"

	insinto "${GITORIOUS_DIR}"
	doins -r .
	keepdir "${GITORIOUS_DIR}/repositories"
	keepdir "${GITORIOUS_DIR}/tarballs"
	keepdir "${GITORIOUS_DIR}/tmp/pids"
	fperms -R +x "${GITORIOUS_DIR}/script"

	fowners -R git:git \
		"${GITORIOUS_DIR}" \
		/var/log/${PN}

	# if use passenger
	has_apache
	insinto "${APACHE_VHOSTS_CONFDIR}"
	doins "${FILESDIR}/10_gitorious_vhost.conf"

	newinitd "${FILESDIR}/gitorious-poller.initd" gitorious-poller

	doenvd "${T}/50${PN}"
}

# -D PASSENGER

pkg_config() {
	if [ ! -e "${EPREFIX}${GITORIOUS_DIR}/config/database.yml" ] ; then
		eerror "Copy ${EPREFIX}${GITORIOUS_DIR}/config/database.yml.example to ${EPREFIX}${GITORIOUS_DIR}/config/database.yml and edit this file in order to configure your database settings for \"production\" environment."
		die
	fi

	local RAILS_ENV=${RAILS_ENV:-production}
	local RUBY=${RUBY:-ruby18}
	local DOMAIN="gitorious.test"
	local USE_SSL=false
	if use ssl; then
		USE_SSL=true
	fi

	cd "${ROOT}${GITORIOUS_DIR}"
	RAILS_ENV="${RAILS_ENV}" bundle install --deployment

	echo
	echo "Please enter wanted host name for Gitorious:"
	read DOMAIN

	einfo
	einfo "RAILS_ENV=${RAILS_ENV}"
	einfo "RUBY=${RUBY}"
	einfo "DOMAIN=${DOMAIN}"
	einfo
	einfo "Building configs:"

	einfo "    gitorious.yml ..."
	SAMPLE="${ROOT}${GITORIOUS_DIR}/config/gitorious.sample.yml"
	CONFIG="${ROOT}${GITORIOUS_DIR}/config/gitorious.yml"
	COOKIE_SECRET="$(dd if=/dev/urandom count=8 bs=64 2>/dev/null | sha256sum | cut -d' ' -f1)"
	# copy sample before RAILS_ENV section
	cat "${SAMPLE}" | sed -n '
		1,/^'${RAILS_ENV}':/p
	' >"${CONFIG}" || die
	# generate RAILS_ENV section based on test section
	cat "${SAMPLE}" | sed -n '
		1,/^test:/d;
		:p;/^[a-z].*:/!{p;n;bp};
		q
	' | sed -r \
		-e "s#^(\s*cookie_secret:).*#\1 \"${COOKIE_SECRET}\"#" \
		-e "s#^(\s*repository_base_path:).*#\1 \"${ROOT}${GITORIOUS_DIR}/repositories\"#" \
		-e "s#^(\s*gitorious_host:).*#\1 ${DOMAIN}#" \
		-e "s#^(\s*gitorious_user:).*#\1 ${GIT_USER}#" \
		-e "s#^(\s*use_ssl:).*#\1 ${USE_SSL}#" \
		>>"${CONFIG}" || die
	echo >>"${CONFIG}" || die
	# copy sample after production section
	cat "${SAMPLE}" | sed -n '
		1,/^'${RAILS_ENV}':/d;
		:n;/^[a-z].*:/!{n;bn};
		:p;p;n;bp
	' >>"${CONFIG}" || die
	chown git:git "${CONFIG}"

	einfo "    broker.yml ..."

	einfo "    10_gitorious_vhost.conf ..."
	sed -i -r \
		-e "s#^(\s*ServerName)\s.*#\1 ${DOMAIN}#" \
		-e "s#^(\s*RailsEnv)\s.*#\1 ${RAILS_ENV}#" \
		"${APACHE_VHOSTS_CONFDIR}/10_gitorious_vhost.conf" || die

	einfo # Done

	RAILS_ENV="${RAILS_ENV}" bundle exec rake db:create
	RAILS_ENV="${RAILS_ENV}" bundle exec rake db:migrate || die

	RAILS_ENV="${RAILS_ENV}" bundle exec rake ultrasphinx:configure

	RAILS_ENV="${RAILS_ENV}" bundle exec ${RUBY} script/create_admin

	#crontab RAILS_ENV="production" /usr/bin/bundle exec /usr/bin/rake ultrasphinx:index
}
