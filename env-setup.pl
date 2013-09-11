#!/usr/bin/perl -w
 use strict;
 use warnings;
 use File::Path;
 use File::Copy;
 use DBI;
 use IO::Prompt;
 use Cwd;

# GLOBAL HELPERS
sub connect_db {
   my $printable_pw = $_[1];
   $printable_pw =~ s/./*/g;
   print STDOUT "Connecting to MySQL database with user=$_[0], password=$printable_pw\n";
   my $dbh = DBI->connect("dbi:mysql:mysql", "$_[0]", "$_[1]")
      or die "Connection Error: $DBI::errstr\n";
   print STDOUT "Connected ok\n";
   return $dbh;
}

sub disconnect_db {
   $_[0]->disconnect;
}

sub query_db {
   my $query_str = $_[1];
   my $printable_query_str = $query_str;
   $printable_query_str =~ s/$password/REDACTED/g;
   print STDOUT "Running query: $printable_query_str\n";
   my $dbh = $_[0];
   my $sth = $dbh->prepare($query_str);
   $sth->execute
      or die "SQL Error: $DBI::errstr\n";
   if (index ($_[1], "SELECT") == 0) {
      return $sth->fetchall_arrayref;
   } else {
      return undef;
   }
}

sub promptSite() {
   while (prompt "\nWhat domain name are you installing Wordpress for [example.com]? ", -while => qr/^$/) {}
   local $site = trim ($_);
   if (index ($site, 'www.') == 0) {
      $site = substr ($site, 4);
   }
   return $site;
}

# MAIN
my $cwd = getcwd();
my $site = "";
if (scalar(@ARGV) > 0) {
   $site = $ARGV[0];
}
if ($site eq "") {
   $site = promptSite();
}

my $user = "$site";
$user =~ s/\./_/g;

print STDOUT "\nStarting installation...\n\n";
my $cont = prompt ("Continue installing $site? [y/n]: ", -ynd => "y");
if (!$cont) {
   print STDOUT "Installation aborted\n\n";
   exit (0);
}

my $email = prompt ("Site administrator email [ENTER to skip]: ");
if (length ($email) == 0) {
   $email = "webmaster\@localhost";
}

print STDOUT "Installing Wordpress dependencies... (Apache2, MySQL Server, PHP)\n\n";

# install Apache2
run ("apt-get", "install", "-y", "apache2");

# install Mysql
run ("apt-get", "install", "-y", "mysql-server", "libapache2-mod-auth-mysql", "php5-mysql");
run ("mysql_install_db");
run ("/usr/bin/mysql_secure_installation");

# install PHP
run ("apt-get", "install", "-y", "php5", "libapache2-mod-php5", "php5-mcrypt");

# important this variable is global for query builder in db_query()
$password = "";

my ($name, $passwd, $uid, $gid, $quota, $comment, $gcos, $dir, $shell) = getpwnam ($user);
if (!$name && !$passwd && !$uid && !$gid && !$quota && !$comment && !$gcos && !$dir && !$shell) {
   $password =  prompt ("Choose a password for your Wordpress user $user: ", -e=>"*");
   while (prompt "Repeat password: ", -echo => "*", -until => "$password") {}

   my $md5password = `openssl passwd -1 $password`;
   chomp ($md5password);
   run (
      "/usr/sbin/useradd",
      "-s", "/bin/bash",
      "-d", "/home/$user",
      "-p", $md5password,
      $user
   );
   ($name, $passwd, $uid, $gid, $quota, $comment, $gcos, $dir, $shell) = getpwnam ($user)
      or die "Wordpress user does not exist - not found in passwd file";
} else {
   $password =  prompt ("Enter the password for existing Wordpress user $user: ", -e=>"*");
}
unless (-e "/home/$user") {
   mkdir "/home/$user";
}
chown $uid, $gid, ("/home/$user");

if (-d "/var/www/$site") {
   my $overwrite = prompt ("Wordpress already installed at /var/www/$site... overwrite? [y/n]: ", -yn);
   if ($overwrite) {
      rmtree ("/var/www/$site") or die "Error deleting existing Wordpress install: $!";
   } else {
      print STDOUT "Aborted installation\n";
      exit (0);
   }
}

# prepare Mysql for Wordpress
print STDOUT "Setting up MySQL Database for $site\n";
my $mysql_user = prompt ("MySQL username (for root press enter): ", -d => "root");
$mysql_user = trim ($mysql_user);
my $mysql_pw = prompt ("MySQL password: ", -e=>"*");

# mysql user name can't be longer than 16 characters
my $wordpress_db_user = $user;
if (length ($wordpress_db_user) > 16) {
   $wordpress_db_user = substr ($wordpress_db_user, 0, 16);
   print STDOUT "Due to mysql 16 char user name limit truncated wordpress db user name to: $wordpress_db_user\n";
}

my $dbh = connect_db ($mysql_user, $mysql_pw);
query_db ($dbh, "CREATE DATABASE IF NOT EXISTS $user");
my $users = query_db ($dbh, "SELECT User FROM mysql.user WHERE User = '$wordpress_db_user'");
if (scalar (@$users) == 0) {
   query_db ($dbh, "CREATE USER $wordpress_db_user\@localhost");
}
query_db ($dbh, "SET PASSWORD FOR $wordpress_db_user\@localhost = PASSWORD('$password')");
query_db ($dbh, "GRANT ALL PRIVILEGES ON $user.* TO $wordpress_db_user\@localhost IDENTIFIED BY '$password'");
query_db ($dbh, "FLUSH PRIVILEGES");
disconnect_db ($dbh);

# install Wordpress
if (-e "$cwd/latest.tar.gz") {
   unlink ("$cwd/latest.tar.gz");
}
run ("wget", "http://wordpress.org/latest.tar.gz");
run ("tar", "-xzvf", "$cwd/latest.tar.gz");

move ("$cwd/wordpress", "$cwd/$site");

open my $in,  '<', "$cwd/$site/wp-config-sample.php" or die "Can't read old file: $!";
open my $out, '>', "$cwd/$site/wp-config.php" or die "Can't write new file: $!";
while (my $line = <$in>) {
   chomp ($line);
   if (index ($line, "database_name_here") != -1) {
      print $out "define('DB_NAME', '$user');\n";
   } elsif (index ($line, "username_here") != -1) {
      print $out "define('DB_USER', '$wordpress_db_user');\n";
   } elsif (index ($line, "password_here") != -1) {
      print $out "define('DB_PASSWORD', '$password');\n";
   } else {
      print $out "$line\n";
   }
}
close $in;
close $out;

move ("$cwd/$site", "/var/www/$site");

# create new site .htaccess vhost override
open my $htaccess, '>', "/var/www/$site/.htaccess" or die "Can't create .htaccess file $!";
print $htaccess "# BEGIN WordPress\n\n";
print $htaccess "<IfModule mod_rewrite.c>\n";
print $htaccess "\tRewriteEngine On\n";
print $htaccess "\tRewriteBase /$site/\n";
print $htaccess "\tRewriteRule ^index\.php\$ - [L]\n";
print $htaccess "\tRewriteCond %{REQUEST_FILENAME} !-f\n";
print $htaccess "\tRewriteCond %{REQUEST_FILENAME} !-d\n";
print $htaccess "\tRewriteRule . /$site/index.php [L]\n";
print $htaccess "</IfModule>\n\n";
print $htaccess "# END WordPress\n";
close $htaccess;

run ("chown", "-R", "www-data:www-data", "/var/www/$site");
run ("usermod", "-G", "www-data", "-a", "$user");
run ("apt-get", "install", "-y", "php5-gd");

# create new site vhost configuration from the default site
open my $vhost_in,  '<', "/etc/apache2/sites-available/default" or die "Can't read old file: $!";
open my $vhost_out, '>', "/etc/apache2/sites-available/$site" or die "Can't write new file: $!";
while (my $line = <$vhost_in>) {
   chomp ($line);
   if (index ($line, "DocumentRoot") != -1) {
      print $vhost_out "\tDocumentRoot /var/www/$site\n";
   } elsif (index ($line, "ServerAdmin") != -1) {
      print $vhost_out "\tServerAdmin $email\n";
      print $vhost_out "\tServerName $site\n";
      print $vhost_out "\tServerAlias www.$site\n";
   } elsif (index ($line, "AllowOverride None") != -1) {
      print $vhost_out "\t\tAllowOverride All\n";
   } else {
      print $vhost_out "$line\n";
   }
}
close $vhost_in;
close $vhost_out;

# set AllowOverride on default site to avoid mod_rewrite issues
open my $default_in,  '<', "/etc/apache2/sites-available/default" or die "Can't read old file: $!";
open my $default_copy_out, '>', "/etc/apache2/sites-available/default-copy" or die "Can't write new file: $!";
while (my $line = <$default_in>) {
   chomp ($line);
   if (index ($line, "AllowOverride None") != -1) {
      print $default_copy_out "\t\tAllowOverride All\n";
   } else {
      print $default_copy_out "$line\n";
   }
}
close $default_in;
close $default_copy_out;
move ("/etc/apache2/sites-available/default-copy", "/etc/apache2/sites-available/default");

# enabling new site
run ("a2ensite", $site);

# enabling mod rewrite for permalinks
run ("a2enmod", "rewrite");

# reload Apache
run ("service", "apache2", "reload");

# restart Apache
run ("service", "apache2", "restart");

print STDOUT "\n\n";
print STDOUT "Wordpress installation complete\n\n";
print STDOUT "To finish the Wordpress website setup go to:\n";
print STDOUT "\t$site/wp-admin/install.php\n";
print STDOUT "\n\n";
