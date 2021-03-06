#!/bin/bash

# this file is executed in a subshell - set up the common stuff
source maint/travis-ci_scripts/common.bash

if [[ -n "$SHORT_CIRCUIT_SMOKE" ]] ; then exit 0 ; fi

# poison the environment
if [[ "$POISON_ENV" = "true" ]] ; then

  # in addition to making sure tests do not rely on implicid order of
  # returned results, look through lib, find all mentioned ENVvars and
  # set them to true and see if anything explodes
  for var in \
    DBICTEST_SQLITE_REVERSE_DEFAULT_ORDER \
    $(grep -P '\$ENV\{' -r lib/ --exclude-dir Optional | grep -oP '\bDBIC\w+' | sort -u | grep -v DBIC_TRACE)
  do
    if [[ -z "${!var}" ]] ; then
      export $var=1
      echo "POISON_ENV: setting $var to 1"
    fi
  done

  # bogus nonexisting DBI_*
  export DBI_DSN="dbi:ODBC:server=NonexistentServerAddress"
  export DBI_DRIVER="ADO"


  # emulate a local::lib-like env
  # trick cpanm into executing true as shell - we just need the find+unpack
  run_or_err "Downloading latest stable DBIC from CPAN" \
    "SHELL=/bin/true cpanm --look DBIx::Class::Schema::Loader"

  export PERL5LIB="$( ls -d ~/.cpanm/latest-build/DBIx-Class-Schema-Loader-*/lib | tail -n1 ):$PERL5LIB"

  # perldoc -l <mod> searches $(pwd)/lib in addition to PERL5LIB etc, hence the cd /
  echo_err "Latest stable DBIC (without deps) locatable via \$PERL5LIB at $(cd / && perldoc -l DBIx::Class::Schema::Loader)"

  # FIXME - this is a kludge in place of proper MDV testing. For the time
  # being simply use the minimum versions of our DBI/DBDstack, to avoid
  # fuckups like 0.08260 (went unnoticed for 5 months)
  #
  # use url-spec for DBI due to https://github.com/miyagawa/cpanminus/issues/328
  if perl -M5.013003 -e1 &>/dev/null ; then
    # earlier DBI will not compile without PERL_POLLUTE which was gone in 5.14
    parallel_installdeps_notest T/TI/TIMB/DBI-1.614.tar.gz
  else
    parallel_installdeps_notest T/TI/TIMB/DBI-1.57.tar.gz
  fi

  # Test both minimum DBD::SQLite and minimum BigInt SQLite
  if [[ "$CLEANTEST" = "true" ]]; then
    parallel_installdeps_notest DBD::SQLite@1.37
  else
    parallel_installdeps_notest DBD::SQLite@1.29
  fi

fi

if [[ "$CLEANTEST" = "true" ]]; then
  # The first CPAN which is somewhat sane is around 1.94_56 (perl 5.12)
  # The problem is that the first sane version also brings a *lot* of
  # deps with it, notably things like YAML and HTTP::Tiny
  # The goal of CLEANTEST is to have as little extra stuff installed as
  # possible, mainly to catch "but X is perl core" mistakes
  # So instead we still use our stock (possibly old) CPAN, and add some
  # handholding

  if ! CPAN_is_sane ; then
    # no configure_requires - we will need the usual suspects anyway
    # without pre-installing these in one pass things like extract_prereqs won't work
    installdeps ExtUtils::MakeMaker ExtUtils::CBuilder Module::Build

  fi

else
  # we will be running all dbic tests - preinstall lots of stuff, run basic tests
  # using SQLT and set up whatever databases necessary
  export DBICTEST_SQLT_DEPLOY=1

  # Include Moose-using tests
  export SCHEMA_LOADER_TESTS_USE_MOOSE=1

  # do the preinstall in several passes to minimize amount of cross-deps installing
  # multiple times, and to avoid module re-architecture breaking another install
  # (e.g. once Carp is upgraded there's no more Carp::Heavy,
  # while a File::Path upgrade may cause a parallel EUMM run to fail)
  #
  parallel_installdeps_notest ExtUtils::MakeMaker
  parallel_installdeps_notest File::Path
  parallel_installdeps_notest Carp
  parallel_installdeps_notest Module::Build
  parallel_installdeps_notest File::Spec Data::Dumper Module::Runtime
  parallel_installdeps_notest Test::Exception Encode::Locale Test::Fatal
  parallel_installdeps_notest Test::Warn B::Hooks::EndOfScope Test::Differences HTTP::Status
  parallel_installdeps_notest Test::Pod::Coverage Test::EOL Test::NoTabs Test::Strict Devel::GlobalDestruction Sub::Util MRO::Compat Class::XSAccessor URI::Escape HTML::Entities
  parallel_installdeps_notest YAML LWP Class::Trigger JSON::XS DateTime::Format::Builder Class::Accessor::Grouped Package::Variant
  parallel_installdeps_notest SQL::Abstract Moose Module::Install JSON SQL::Translator File::Which
  parallel_installdeps_notest Module::Install::ReadmeFromPod Module::Install::AuthorTests
  parallel_installdeps_notest Math::Base36 DBD::mysql DBD::Pg Math::BigInt
  parallel_installdeps_notest MooseX::NonMoose MooseX::MarkAsMethods namespace::autoclean curry

  if env | grep -q '^DBICTEST_.*_ODBC_DSN'; then
    parallel_installdeps_notest DBD::ODBC
  fi
  if [[ -n "$DBICTEST_ORA_DSN" ]]; then
    parallel_installdeps_notest DBD::Oracle
  fi
  if [[ -n "$DBICTEST_DB2_DSN" ]]; then
    parallel_installdeps_notest DBD::DB2
  fi
  if [[ -n "$DBICTEST_FIREBIRD_DSN" ]]; then
    parallel_installdeps_notest DBD::Firebird
  fi

  if [[ -n "$DBICTEST_FIREBIRD_INTERBASE_DSN" ]] ; then
    # the official version is very much outdated and does not compile on 5.14+
    # use this rather updated source tree (needs to go to PAUSE):
    # https://github.com/pilcrow/perl-dbd-interbase
    parallel_installdeps_notest git://github.com/dbsrgits/perl-dbd-interbase.git
  fi

fi

# generate the MYMETA which will have different deps depending on
# the runmode and envvars set above
run_or_err "Configure on current branch" "perl Makefile.PL"

# install (remaining) dependencies, sometimes with a gentle push
if [[ "$CLEANTEST" = "true" ]]; then
  # we may need to prepend some stuff to that list
  HARD_DEPS="$(extract_prereqs .)"

##### TEMPORARY WORKAROUNDS needed in case we will be using CPAN.pm
  if [[ "$DEVREL_DEPS" != "true" ]] && ! CPAN_is_sane ; then
    # combat dzillirium on harness-wide level, otherwise breakage happens weekly
    echo_err "$(tstamp) Ancient CPAN.pm: engaging TAP::Harness::IgnoreNonessentialDzilAutogeneratedTests during dep install"
    perl -MTAP::Harness\ 3.18 -e1 &>/dev/null || run_or_err "Upgrading TAP::Harness for HARNESS_SUBCLASS support" "cpan TAP::Harness"
    export PERL5LIB="$(pwd)/maint/travis-ci_scripts/lib:$PERL5LIB"
    export HARNESS_SUBCLASS="TAP::Harness::IgnoreNonessentialDzilAutogeneratedTests"
    # sanity check, T::H does not report sensible errors when the subclass fails to load
    perl -MTAP::Harness::IgnoreNonessentialDzilAutogeneratedTests -e1

    # DBD::SQLite reasonably wants DBI at config time
    perl -MDBI -e1 &>/dev/null || HARD_DEPS="DBI $HARD_DEPS"

    # this is a fucked CPAN - won't understand configure_requires of
    # various pieces we may run into
    # FIXME - need to get these off metacpan or something instead
    HARD_DEPS="ExtUtils::Depends B::Hooks::OP::Check $HARD_DEPS"

    if CPAN_supports_BUILDPL ; then
      # We will invoke a posibly MBT based BUILD-file, but we do not support
      # configure requires. So we not only need to install MBT but its prereqs
      # FIXME This is madness
      HARD_DEPS="$(extract_prereqs Module::Build::Tiny) Module::Build::Tiny $HARD_DEPS"
    else
      # FIXME
      # work around Params::Validate not having a Makefile.PL so really old
      # toolchains can not figure out what the prereqs are ;(
      # Need to do more research before filing a bug requesting Makefile inclusion
      HARD_DEPS="$(extract_prereqs Params::Validate) $HARD_DEPS"
    fi
  fi
##### END TEMPORARY WORKAROUNDS

  installdeps $HARD_DEPS

### FIXME in case we set it earlier in a workaround
  if [[ -n "$HARNESS_SUBCLASS" ]] ; then

    INSTALLDEPS_SKIPPED_TESTLIST=$(perl -0777 -e '
my $curmod_re = qr{
^
  (?:
    \QBuilding and testing\E
      |
    [\x20\t]* CPAN\.pm: [^\n]*? (?i:build)\S*
  )

  [\x20\t]+ (\S+)
$}mx;

my $curskip_re = qr{^ === \x20 \QSkipping nonessential autogenerated tests: \E([^\n]+) }mx;

my (undef, @chunks) = (split qr/$curmod_re/, <>);
while (@chunks) {
  my ($mod, $log) = splice @chunks, 0, 2;
  print "!!! Skipped nonessential tests while installing $mod:\n\t$1\n"
    if $log =~ $curskip_re;
}
' <<< "$LASTOUT")

    if [[ -n "$INSTALLDEPS_SKIPPED_TESTLIST" ]] ; then
      POSTMORTEM="$POSTMORTEM$(
        echo
        echo "The following non-essential tests were skipped during deps installation"
        echo "============================================================="
        echo "$INSTALLDEPS_SKIPPED_TESTLIST"
        echo "============================================================="
        echo
      )"
    fi

    unset HARNESS_SUBCLASS
  fi

else

  # listalldeps is deliberate - will upgrade everything it can find
  deplist="$(listalldeps)"

  # assume MDV on POISON_ENV, do not touch DBI/SQLite
  if [[ "$POISON_ENV" = "true" ]] ; then
    deplist="$(grep -vP '^(DBI|DBD::SQLite)$' <<< "$deplist")"
  fi

  parallel_installdeps_notest "$deplist"
fi

echo_err "$(tstamp) Dependency installation finished"
# this will display list of available versions
perl Makefile.PL

# make sure we got everything we need
if [[ -n "$(extract_prereqs .)" ]] ; then
  echo_err "$(tstamp) Not all deps installed - something went wrong :("
  sleep 1 # without this the echo below confuses the console listener >.<
  CPAN_is_sane || echo_err -e "Outdated CPAN.pm used - full installdep log follows\n$INSTALLDEPS_OUT\n\nSearch for 'NOT OK' in the text above\n\nDeps still missing:"
  sleep 3 # without this the above echo confuses the console listener >.<
  extract_prereqs .
  exit 1
fi

# check that our MDV somewhat works
if [[ "$POISON_ENV" = "true" ]] && ( perl -MDBD::SQLite\ 1.38 -e1 || perl -MDBI\ 1.615 -e1 ) &>/dev/null ; then
  echo_err "Something went wrong - higher versions of DBI and/or DBD::SQLite than we expected"
  exit 1
fi


# announce what are we running
echo_err "
===================== DEPENDENCY CONFIGURATION COMPLETE =====================
$(tstamp) Configuration phase seems to have taken $(date -ud "@$SECONDS" '+%H:%M:%S') (@$SECONDS)

$(ci_vm_state_text)"
