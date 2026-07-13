use strict;
use warnings;

use FindBin;
use Test::More;

BEGIN {
  package Log::Dispatch;

  $INC{'Log/Dispatch.pm'} = __FILE__;

  package MHA::NodeConst;

  our $SSH_OPT_ALIVE = '';

  $INC{'MHA/NodeConst.pm'} = __FILE__;

  package MHA::NodeUtil;

  sub get_ip {
    return '127.0.0.1';
  }

  sub escape_for_shell {
    return $_[0];
  }

  sub escape_for_mysql_command {
    return $_[0];
  }

  $INC{'MHA/NodeUtil.pm'} = __FILE__;

  package MHA::SlaveUtil;

  $INC{'MHA/SlaveUtil.pm'} = __FILE__;

  package MHA::Server;

  sub new {
    return bless {}, shift;
  }

  $INC{'MHA/Server.pm'} = __FILE__;
}

use lib "$FindBin::Bin/../lib";

require MHA::Config;
require MHA::HealthCheck;

{
  package Local::Logger;

  sub new {
    return bless {}, shift;
  }

  sub info {
    return;
  }

  sub warning {
    return;
  }
}

{
  package Local::FailingHealthCheck;

  our @ISA = ('MHA::HealthCheck');

  sub connect {
    my ($self) = @_;
    $self->{connect_calls}++;
    return ( 1, undef );
  }

  sub sleep_until {
    return;
  }

  sub handle_failing {
    return;
  }

  sub is_ssh_reachable {
    return 0;
  }

  sub is_secondary_down {
    return 1;
  }
}

{
  package Local::FailingPingHealthCheck;

  our @ISA = ('Local::FailingHealthCheck');

  sub connect {
    my ($self) = @_;
    $self->{connect_calls}++;
    return 0;
  }

  sub fork_exec {
    my ($self) = @_;
    $self->{ping_calls}++;
    return 1;
  }
}

subtest 'configuration handles the failure threshold' => sub {
  my $config = MHA::Config->new();
  my $empty_default = MHA::Server->new();

  my $server = $config->parse_server(
    { hostname => 'db1' },
    $empty_default
  );
  is( $server->{ping_max_failures}, 4, 'default threshold is four' );

  my $app_default = $config->parse_server(
    { hostname => 'db1', ping_max_failures => 7 },
    $empty_default
  );
  $server = $config->parse_server(
    { hostname => 'db2' },
    $app_default
  );
  is( $server->{ping_max_failures}, 7, 'threshold is inherited' );

  $server = $config->parse_server(
    { hostname => 'db2', ping_max_failures => 2 },
    $app_default
  );
  is( $server->{ping_max_failures}, 2, 'server threshold overrides default' );

  for my $invalid ( 0, -1, 'invalid' ) {
    my $error;
    eval {
      $config->parse_server(
        { hostname => 'db1', ping_max_failures => $invalid },
        $empty_default
      );
    };
    $error = $@;
    like(
      $error,
      qr/Parameter ping_max_failures must be positive integer/,
      "value $invalid is rejected"
    );
  }
};

subtest 'health check uses the configured failure threshold' => sub {
  for my $case (
    { expected => 4 },
    { configured => 2, expected => 2 },
  ) {
    my @arguments = (
      logger => Local::Logger->new(),
    );
    push @arguments, ping_max_failures => $case->{configured}
      if ( defined( $case->{configured} ) );

    my $health = Local::FailingHealthCheck->new(@arguments);
    my ( $return_code, $ssh_reachable ) = $health->wait_until_unreachable();

    is( $return_code, 0, 'master is reported as unreachable' );
    is( $ssh_reachable, 0, 'SSH result is propagated' );
    is(
      $health->{connect_calls},
      $case->{expected},
      "threshold $case->{expected} is honored"
    );
  }
};

subtest 'failed query pings also honor the threshold' => sub {
  my $health = Local::FailingPingHealthCheck->new(
    logger            => Local::Logger->new(),
    ping_type         => 'SELECT',
    ping_max_failures => 2,
  );

  my ( $return_code, $ssh_reachable ) = $health->wait_until_unreachable();

  is( $return_code, 0, 'master is reported as unreachable' );
  is( $ssh_reachable, 0, 'SSH result is propagated' );
  is( $health->{ping_calls}, 2, 'two failed query pings reach the threshold' );
};

done_testing();
