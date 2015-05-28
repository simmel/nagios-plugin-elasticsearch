#!/usr/bin/env perl
# Copyright (c) 2013-, Simon Lundström <simlu@su.se>, IT Services, Stockholm University
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# Neither the name of Stockholm University nor the names of its contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
use strict;
use warnings;
use JSON;
use Nagios::Plugin;
use Data::Dumper;
use LWP::UserAgent;

# TODO
# * Add warnings
# * Check that index/shard status is status or higher.
my $np = Nagios::Plugin->new(
  shortname => "#",
  usage => "Usage: %s [-v|--verbose] [-t <timeout>] [--critical=<critical cluster status>]",
  timeout => 10,
  extra => qq(
See <https://nagios-plugins.org/doc/guidelines.html#THRESHOLDFORMAT> for
information on how to use thresholds.

The STATUS label can have three values:
* green - All primary and replica shards are allocated. Your cluster is 100%
operational.
* yellow - All primary shards are allocated, but at least one replica is
missing. No data is missing, so search results will still be complete. However,
your high availability is compromised to some degree. If more shards disappear,
you might lose data. Think of yellow as a warning that should prompt
investigation.
* red - At least one primary shard (and all of its replicas) are missing. This
means that you are missing data: searches will return partial results, and
indexing into that shard will return an exception.

The defaults has been been taken from
<https://www.elastic.co/guide/en/elasticsearch/guide/current/_cluster_health.html>
),
);

$np->add_arg(
  spec => 'cluster-status',
  help => "--cluster-status\n   Check the status of the cluster.",
);

$np->add_arg(
  spec => 'warning|w=s',
  help => [
    'Set the warning threshold in INTEGER (applies to nodes-online)',
    'Set the warning threshold in STATUS (applies to cluster-status and index-status)',
  ],
  label => [ 'INTEGER', 'STATUS' ],
);

$np->add_arg(
  spec => 'critical|c=s',
  help => [
    'Set the critical threshold in INTEGER (applies to nodes-online)',
    'Set the critical threshold in STATUS (applies to cluster-status and index-status)',
  ],
  label => [ 'INTEGER', 'STATUS' ],
);

$np->add_arg(
  spec => 'url=s',
  help => "--url\n   URL to your Elasticsearch instance. (default: %s)",
  default => 'http://localhost:9200',
);

$np->getopts;

my %ES_STATUS = (
  "red" => 1,
  "yellow" => 2,
  "green" => 3,
);
my ($warning, $critical) = ($np->opts->warning, $np->opts->critical);
my $code;
my $json;

# Turns an array into "first, second & last"
sub pretty_join($) {
  my ($a) = @_;
  join("", map {
    if ($_ eq @$a[@$a-1]) {
      $_;
    }
    else {
      if ($_ eq @$a[@$a-2]) {
        $_.' & ';
      }
      else {
        $_.', ';
      }
    }
  } @$a);
}

# Checks the status of "something"
sub check_status($$) {
  $code = $np->check_threshold(
    check => (ref $_[0] eq "HASH") ? $ES_STATUS{$_[0]->{status}} : $ES_STATUS{$_[0]},
    warning => "\@$ES_STATUS{$warning}",
    critical => "\@$ES_STATUS{$critical}",
  );
  $np->add_message($code, $_[1]);
}

my $ua = LWP::UserAgent->new;
# NRPE timeout is 10 seconds, give us 1 second to run
$ua->timeout($np->opts->timeout-1);
# Time out 1 second before LWP times out.
my $url = $np->opts->url."/_cluster/health?level=shards&timeout=".($np->opts->timeout-2)."s&pretty";
my $resp = $ua->get($url);

if (!$resp->is_success) {
  $np->nagios_exit(CRITICAL, $resp->status_line);
}

$json = $resp->decoded_content;

# Try to parse the JSON
eval {
  $json = decode_json($json);
};
if ($@) {
  $np->nagios_exit(CRITICAL, "JSON was invalid: $@");
}

# Check that the cluster query didn't time out
if (defined $json->{timed_out} && $json->{timed_out}) {
  $np->nagios_exit(CRITICAL, "Connection to cluster timed out!");
}

# Check the status of the cluster.
if ($np->opts->get('cluster-status')) {
  # Set defaults
  $warning = $warning || "yellow";
  $critical = $critical || "red";

  check_status($json, "Cluster $json->{cluster_name} is $json->{status}");
}

else {
  exec ($0, "--help");
}

# Check that we have the number of nodes we prefer online.
$code = $np->check_threshold(
  check => $json->{number_of_nodes},
  warning => $warning,
  critical => $critical,
);
$np->add_message($code, "nodes online: $json->{number_of_nodes}");

# Check all the indices and shards
my $indices_with_issues;
# Loop over all indexes and then shards to find which is critical
# FIXME Make the check a >=yellow check
foreach my $i (keys %{$json->{indices}}) {
  if ($json->{indices}->{$i}->{status} eq $critical) {
    foreach my $s (keys %{$json->{indices}->{$i}->{shards}}) {
      if ($json->{indices}->{$i}->{shards}->{$s}->{status} eq $critical) {
        push @{$indices_with_issues->{$i}}, $s;
      }
    }
  }
}

# Create an joined error string for all indexes and shards
if ($indices_with_issues) {
  my @indices_error_string;
  foreach my $i (keys %$indices_with_issues) {
    push @indices_error_string, "index $i shard(s) ".pretty_join($indices_with_issues->{$i});
  }
  check_status($critical, join(", ", @indices_error_string));
}

($code, my $message) = $np->check_messages(join => ", ");
$np->nagios_exit($code, $message);
