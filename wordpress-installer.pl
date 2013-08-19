#!/usr/bin/perl -w
 use Cwd;

my $cwd = getcwd();
my $log = "$cwd/wordpress-install.log";

# GLOBAL HELPERS
sub trim {
   return $_[0] =~ s/^\s+|\s+$//rg;
}

sub run {
   my $logline = "@_";
   open my $touch, '>>', $log or die $!;
   close $touch;
   system(@_) == 0
      or die "system @_ failed: $?";
   open my $out, '>>', $log or die $!;
   print $out "$logline\n";
   close $out;
   print STDOUT "\n";
}

# MAIN
my $domain_name = ""; #optional
if (scalar(@ARGV) > 0) {
   $domain_name = $ARGV[0];
}

# update Apt repo
run ("apt-get", "-y", "update");

# install DBI Perl module
run ("apt-get", "install", "-y", "libdbi-perl");

# install IO::Prompt Perl module
run ("apt-get", "install", "-y", "libio-prompt-perl");

# download env-setup.pl
run ("wget", "https://raw.github.com/ecolner/wordpress-installer/master/env-setup.pl");
run ("chmod", "a+x", "$cwd/env-setup.pl");

# invoke setup script
do {
   local @ARGV = ($domain_name);
   eval { require "env-setup.pl" };
};
