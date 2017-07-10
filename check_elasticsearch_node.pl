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

my $np = Nagios::Plugin->new(
  shortname => "#",
  usage => "Usage: %s [-v|--verbose] [-t <timeout>] [--critical=<value to emit critical>] [--warning=<value to emit warning>] --one-of-the-checks-below",
  version => "1.3.1",
  timeout => 10,
  extra => qq(
See <https://nagios-plugins.org/doc/guidelines.html#THRESHOLDFORMAT> for
information on how to use thresholds.
The defaults has been been taken from
<http://www.elastic.co/guide/en/elasticsearch/guide/current/_monitoring_individual_nodes.html>
),
);

$np->add_arg(
  spec => 'open-fds',
  help => "--open-fds\n   Check how many file descriptors are open.",
);

$np->add_arg(
  spec => 'jvm-heap-usage',
  help => "--jvm-heap-usage\n   Check how much JVM heap is used.",
);

# TODO Add thread-pool-queued (%)
$np->add_arg(
  spec => 'thread-pool-rejected',
  help => '--thread-pool-rejected\n   Check how many rejected work units the thread pools have.
   You can also set a per thread-pool threshold by prefixing the threshold with "<thread-pool-name>;", e.g: --critical "search;@100000:"',
);

$np->add_arg(
  spec => 'breakers-tripped',
  help => "--breakers-tripped\n   Check how many circuit breakers that have been tripped.",
);

$np->add_arg(
  spec => 'breakers-size',
  help => "--breakers-size\n   Check how near we are the circuit breaker size limit.",
);

$np->add_arg(
  spec => 'warning|w=s',
  help => [
    'Set the warning threshold in INTEGER (applies to breakers-tripped and thread-pool-rejected)',
    'Set the warning threshold in PERCENT (applies to open-fds, jvm-heap-used, breakers-size)',
  ],
  label => [ 'INTEGER', 'PERCENT%' ],
);

$np->add_arg(
  spec => 'critical|c=s',
  help => [
    'Set the critical threshold in INTEGER (applies to breakers-tripped and thread-pool-rejected)',
    'Set the critical threshold in PERCENT (applies to open-fds, jvm-heap-used, breakers-size)',
  ],
  label => [ 'INTEGER', 'PERCENT%' ],
);

$np->add_arg(
  spec => 'url=s',
  help => "--url\n   URL to your Elasticsearch instance. (default: %s)",
  default => 'http://localhost:9200',
);

$np->add_arg(spec => 'username|user|u=s',
    help => "Username for authentication",
    default => "",
);

$np->add_arg(spec => 'password|p=s',
    help => "Password for authentication",
    default => ""
);

$np->getopts;

sub clean_extra_chars($) {
  my ($ret) = @_;
  $ret =~ s/[^\d\w]//g;
  return $ret;
}

sub convert_to_decimal($) {
  my ($ret) = @_;
  $ret = $_[0]/100;
  return $ret;
}

sub to_threshold($$) {
  my ($ret, $original) = @_;
  $ret =~ s/[\d\w]+%?/$original/;
  return $ret;
}

sub get_json($) {
  my ($url) = @_;
  my $ua = LWP::UserAgent->new;
  # NRPE timeout is 10 seconds, give us 1 second to run
  $ua->timeout($np->opts->timeout-1);
  $url = $np->opts->url.$url;

  my $req = HTTP::Request->new(GET => $url);

  # Username and Password are defined for basic auth
  if ($np->opts->username and $np->opts->password) {
    $req->authorization_basic($np->opts->username, $np->opts->password);
  }

  my $response = $ua->request($req);

  if (!$response->is_success) {
    $np->nagios_exit(CRITICAL, $response->status_line);
  }
  my $json = $response->decoded_content;

  my $result;
  # Try to parse the JSON
  eval {
    $result = decode_json($json);
  };
  if ($@) {
    $np->nagios_exit(CRITICAL, "JSON was invalid: $@");
  }
  return $result;
}

# Turns an array into "first, second, third & last"
sub pretty_join {
  my $a = shift;

  my @words = @$a;
  my $string = join (', ', @words[0..$#words-1]);
  $string = $string.' & '.$words[$#words];

  return $string;
}

sub get_threshold_value {
  my ($thresh, $value, $key) = @_;

  if (ref $thresh eq 'CODE') {
    return $thresh->($value, $key);
  }
  else {
    return $thresh;
  }
}

# Check a data structure with check_threshold.
# TODO Make sure it works recursively
sub check_each($$$$$) {
  my %statuses;
  my ($what, $where, $warning, $critical, $message) = @_;
  # Run check_threshold on everything
  foreach my $k (keys %$what) {
    my $current_key = $where->($what->{$k});

    my $warn = get_threshold_value($warning, $what->{$k}, $k);
    my $crit = get_threshold_value($critical, $what->{$k}, $k);

    my $code = $np->check_threshold(
      check => $current_key,
      warning => $warn,
      critical => $crit,
    );

    # and put in in a hash where the status is the key and the value an array
    # of the keys with that status
    push @{$statuses{$code}}, $k;
  }
  for my $code (keys %statuses) {
    # We don't care about OK checks, but add messages about everything else.
    if ($code ne 0 && $statuses{$code}) {
      $np->add_message($code, $message.pretty_join($statuses{$code}));
    }
  }
}

sub parse_thresholds {
  my %opt = @_;
  my @thresholds = split(/,/, $opt{threshold});
  @thresholds = map {
    if (/;/) {
      my ($k, $v) = split(/;/, $_);
      $opt{thresholds}{$k} = $v;
      undef;
    }
    else {
      $_;
    }
  } @thresholds;
  @thresholds = grep { defined } @thresholds;
  my $threshold = join('', @thresholds);
  return $threshold;
}

my ($warning, $critical) = ($np->opts->warning, $np->opts->critical);
my $code;
my $json = get_json("/_nodes/_local/stats?pretty");

# Check number of open file descriptors
if ($np->opts->get('open-fds')) {
  # Set defaults
  $warning = $warning || "80%";
  $critical = $critical || "90%";
  $warning = clean_extra_chars($warning);
  $warning = convert_to_decimal($warning);
  $critical = clean_extra_chars($critical);
  $critical = convert_to_decimal($critical);

  my $open_fds = $json->{nodes}->{(keys %{$json->{nodes}})[0]}->{process}->{open_file_descriptors};
  # Get the default number of open file descriptors
  $json = get_json("/_nodes/_local?pretty");
  my $open_fds_max = $json->{nodes}->{(keys %{$json->{nodes}})[0]}->{process}->{max_file_descriptors};

  $code = $np->check_threshold(
    check => $open_fds,
    warning => $open_fds_max*$warning,
    critical => $open_fds_max*$critical,
  );
  $np->add_message($code, "Open file descriptors: $open_fds");
}

# Check how much heap is used.
elsif ($np->opts->get('jvm-heap-usage')) {
  # Set defaults
  # http://www.elastic.co/guide/en/elasticsearch/guide/current/_monitoring_individual_nodes.html#_jvm_section
  # Elasticsearch is configured to initiate GCs when the heap reaches 75% full.
  # If your node is consistently >= 75%, your node is experiencing memory
  # pressure. This is a warning sign that slow GCs may be in your near future.
  $warning = $warning || "75%";
  # If the heap usage is consistently >=85%, you are in trouble. Heaps over
  # 90–95% are in risk of horrible performance with long 10–30s GCs at best,
  # and out-of-memory (OOM) exceptions at worst.
  $critical = $critical || "85%";
  $warning = clean_extra_chars($warning);
  $critical = clean_extra_chars($critical);

  my $jvm_heap_used = $json->{nodes}->{(keys %{$json->{nodes}})[0]}->{jvm}->{mem}->{heap_used_percent};

  $code = $np->check_threshold(
    check => $jvm_heap_used,
    warning => $warning,
    critical => $critical,
  );
  $np->add_message($code, "JVM heap in use: $jvm_heap_used%");
}

# Check how many rejected work units the thread pools have.
elsif ($np->opts->get('thread-pool-rejected')) {
  # Set defaults
  # http://www.elastic.co/guide/en/elasticsearch/guide/current/_monitoring_individual_nodes.html#_threadpool_section
  # If the queue fills up to its limit, new work units will begin to be
  # rejected[…]. This is often a sign that your cluster is starting to
  # bottleneck on some resources, since a full queue means your node/cluster is
  # processing at maximum speed but unable to keep up with the influx of work.
  my (%warnings, %criticals);

  # Set default thresholds if none are set.
  my $default_warning = '@1:';
  my $default_critical = '@5:';
  $warning ||= $default_warning;
  $critical ||= $default_critical;

  # Parse specific thresholds for certain keys
  $warning = parse_thresholds(thresholds => \%warnings, threshold => $warning);
  $critical = parse_thresholds(thresholds => \%criticals, threshold => $critical);

  # Set defaults thresholds *again* if only specific thresholds were supplied
  # i.e: --warning 'search;@10:'
  $warning ||= $default_warning;
  $critical ||= $default_critical;

  my $thread_pool = $json->{nodes}->{(keys %{$json->{nodes}})[0]}->{thread_pool};

  check_each($thread_pool, sub {
      my ($f) = @_;
      return $f->{rejected};
    },
    sub {
      my ($f,$k) = @_;
      return (defined $warnings{$k} ? $warnings{$k} : $warning);
    },
    sub {
      my ($f,$k) = @_;
      return (defined $criticals{$k} ? $criticals{$k} : $critical);
    },
    "Thread pools with rejected threads: "
  );
}

# Check how many circuit breakers that have been tripped.
elsif ($np->opts->get('breakers-tripped')) {
  # Set defaults
  # https://www.elastic.co/guide/en/elasticsearch/guide/current/_monitoring_individual_nodes.html#_circuit_breaker
  # The main thing to watch is the tripped metric. If this number is large or
  # consistently increasing, it’s a sign that your queries may need to be
  # optimized or that you may need to obtain more memory (either per box or by
  # adding more nodes).
  $warning = $warning || '@1:';
  $critical = $critical || '@5:';

  my $breakers = $json->{nodes}->{(keys %{$json->{nodes}})[0]}->{breakers};

  check_each($breakers, sub {
      my ($f) = @_;
      return $f->{tripped};
    },
    $warning,
    $critical,
    "Breakers tripped: "
  );
}

# Check how near we are the circuit breaker size limit.
elsif ($np->opts->get('breakers-size')) {
  # Set defaults
  # https://www.elastic.co/guide/en/elasticsearch/guide/current/_monitoring_individual_nodes.html#_circuit_breaker
  # Determine the maximum circuit-breaker size (for example, at what size the
  # circuit breaker will trip if a query attempts to use more memory).
  # Numbers here are made up my me, they should me sound.
  $warning = $warning || '@75%:';
  $critical = $critical || '@85%:';

  my $breakers = $json->{nodes}->{(keys %{$json->{nodes}})[0]}->{breakers};

  check_each($breakers, sub {
      my ($f) = @_;
      my $estimated_size = $f->{estimated_size_in_bytes};
      return $estimated_size;
    },
    sub {
      my ($f) = @_;
      my $limit_size = $f->{limit_size_in_bytes};
      return to_threshold($warning, ($limit_size*convert_to_decimal(clean_extra_chars($warning))));
    },
    sub {
      my ($f) = @_;
      my $limit_size = $f->{limit_size_in_bytes};
      return to_threshold($critical, ($limit_size*convert_to_decimal(clean_extra_chars($critical))));
    },
    "Breakers over memory limit: "
  );
}

else {
  exec ($0, "--help");
}

($code, my $message) = $np->check_messages();
$np->nagios_exit($code, $message);
