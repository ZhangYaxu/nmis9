#!/usr/bin/perl
#
#  Copyright 1999-2014 Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************
#
# a command-line node administration tool for NMIS 9
use strict;
our $VERSION = "9.0.0a";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use File::Spec;
use Data::Dumper;
use JSON::XS;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;

my $bn = basename($0);
my $usage = "Usage: $bn act=[action to take] [extras...]

\t$bn act=list
\t$bn act={create|update|show} node=nodeX
\t$bn act=export [format=nodes] [file=path] {node=nodeX|group=groupY}
\t$bn act=import_bulk {nodes=filepath|nodeconf=dirpath}
\t$bn act=delete {node=nodeX|group=groupY}

\t$bn act=set node=nodeX entry.X=Y...
\t$bn act=mktemplate [placeholder=1/0]
\t$bn act=rename old=nodeX new=nodeY [entry.A=B...]

mktemplate: prints blank template for node creation,
 optionally with __REPLACE_XX__ placeholder
create: requires file=NewNodeDef.json
export: exports to file=someFile (or STDOUT if no file given),
 either json or as Nodes.nmis if format=nodes is given

update: updates existing node from file=someFile.json (or STDIN)
delete: only deletes if confirm=yes (in uppercase) is given

show: prints the nodes properties in the same format as set
 with option quoted=true, show adds double-quotes where needed
set: adjust one or more node properties

extras: deletedata=<true,false> which makes delete also
delete inventory data and RRD files for a node. default is true.

extras: debug={1..9,verbose} sets debugging verbosity
extras: info=1 sets general verbosity
\n\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^-(h|\?|-help)$/ ));
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

# first we need a config object
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir,
																					debug => $cmdline->{debug},
																					info => $cmdline->{info});
die "no config available!\n" if (ref($config) ne "HASH"
																 or !keys %$config);

# log to stderr if debug or info are given
my $logfile = $config->{'<nmis_logs>'} . "/cli.log"; # shared by nmis-cli and this one
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
																 debug => $cmdline->{debug},
																 info => $cmdline->{info}) // $config->{log_level},
															 path  => (defined($cmdline->{debug})
																				 || defined($cmdline->{info})? undef : $logfile));

# now get us an nmisng object, which has a database handle and all the goods
my $nmisng = NMISNG->new(config => $config, log  => $logger);



# import from nodes file, overwriting existing data in the db
if ($cmdline->{act} =~ /^import[_-]bulk$/
		&& (my $nodesfile = $cmdline->{nodes}))
{
	die "invalid nodes file $nodesfile argument!\n" if (!-f $nodesfile);

	$logger->info("Starting bulk import of nodes");
	my $node_table = NMISNG::Util::readFiletoHash(file => $nodesfile);
	die "nodes file contains no data!\n"
			if (ref($node_table) ne "HASH" or !keys %$node_table);

	my %stats = (created => 0, updated => 0);
	# this kind of thing ALWAYS has key repeated as value 'name'
	foreach my $onenode ( values %$node_table )
	{
		# note that this looks up the node by uuid, exclusively. if the nodes file has dud uuids,
		# then existing nodes will NOT be found.
		my $node = $nmisng->node( uuid => $onenode->{uuid} || NMISNG::Util::getUUID($onenode->{name}),
															create => 1 );
		++$stats{ $node->is_new? "created":"updated" };
		$logger->debug(($node->is_new? "creating": "updating")." node $onenode->{name}");

		# any node on this system must have this system's cluster_id.
		$onenode->{cluster_id} = $config->{cluster_id};

		# and OVERWRITE the configuration
		my $curconfig = $node->configuration; # mostly empty when new
		for my $copyable (grep($_ ne "_id", keys %$onenode)) # must not trash that attrib
		{
			$curconfig->{$copyable} = $onenode->{$copyable};
		}
		$node->configuration($curconfig);

		# and save
		my ($op,$error) = $node->save();
		if($op <= 0)									# zero is no saving needed
		{
			$logger->error("Error saving node ".$node->name.": $error");
		}
		else
		{
			$logger->debug( $node->name." saved to database, op: $op" );
		}
	}
	$logger->info("Bulk import complete, newly created $stats{created}, updated $stats{updated} nodes");
	exit 0;
}
elsif ($cmdline->{act} =~ /^import[_-]bulk$/
			 && (my $nodeconfdir = $cmdline->{nodeconf}))
{
	die "invalid nodeconf directory $nodeconfdir!\n" if (!-d $nodeconfdir);

	$logger->info( "Starting bulk import of node-conf overrides");

	opendir( D, $nodeconfdir ) or die "Cannot open nodeconf dir $nodeconfdir: $!\n";
	my @cands = grep( /^[a-z0-9_-]+\.json$/, readdir(D) );
	closedir(D);

	die "No nodeconfig data in $nodeconfdir!\n" if (!@cands);

	my $counter = 0;
	for my $maybe (@cands)
	{
		my $data = NMISNG::Util::readFiletoHash( file => "$nodeconfdir/$maybe", json => 1 );
		if ( ref($data) ne "HASH" or !keys %$data or !$data->{name} )
		{
			$logger->error("nodeconf $nodeconfdir/$maybe had invalid data! Skipping.");
			next;
		}

		# get the node, don't create it, it must exist already
		my $node_name = $data->{name};
		my $node = $nmisng->node( name => $node_name );
		if ( !$node )
		{
			$logger->error("cannot import nodeconf for $data->{name} because node does not exist! Skipping.");
			next;
		}

		++$counter;

		# don't bother saving the name in it
		delete $data->{name};
		$node->overrides($data);

		my ($op,$error) = $node->save();
		$logger->error("Error saving node: ",$error) if ($op <= 0); # zero is no saving needed

		$logger->debug( "imported nodeconf for $node_name, overrides saved to database, op: $op" );
	}

	$logger->info("Bulk import complete, updated overrides for $counter nodes");
	exit 0;
}
elsif ($cmdline->{act} eq "list")
{
	# just list the nodes in existence - just their names
	my $nodelist = $nmisng->get_node_names;
	if (ref($nodelist) ne "ARRAY" or !@$nodelist)
	{
		print STDERR "No nodes exist.\n"; # but not an error, so let's not die
	}
	else
	{
		print "Node Names:\n===========\n" if (-t \*STDOUT); # if to terminal, not pipe etc.
		print join("\n",sort @$nodelist),"\n";
	}
	exit 0;
}
elsif ($cmdline->{act} eq "export")
{
	my ($node,$group,$file,$wantformat) = @{$cmdline}{"node","group","file","format"};

	# no node, no group => export all of them
	die "File \"$file\" already exists, NOT overwriting!\n" if (defined $file && $file ne "-" && -f $file);

	my $nodemodel = $nmisng->get_nodes_model(name => $node, group => $group);
	die "No matching nodes exist\n" if (!$nodemodel->count);

	my $fh;
	if (!$file or $file eq "-")
	{
		$fh = \*STDOUT;
	}
	else
	{
		open($fh,">$file") or die "cannot write to $file: $!\n";
	}
	# array of hashes, 1 or more
	my $allofthem = $nodemodel->data;
	# ...except that the _id doesn't do us any good on export
	map { delete $_->{_id}; } (@$allofthem);

	# ...and if format=nodes is requested, ditch the nodeconf overrides and dummy addresses as well
	# nodes.nmis is a hash of nodename => FLAT record
	if (defined($wantformat) && $wantformat eq "nodes")
	{
		map { delete $_->{overrides}; delete $_->{addresses}; } (@$allofthem);
		my %compathash = map { ($_->{name} => $_) } (@$allofthem);

		print $fh Data::Dumper->new([\%compathash],[qw(*hash)])->Sortkeys(1)->Dump;
	}
	else
	{
		# if just one node was wanted then we write a hash; in all other cases
		# we write the array
		my $which = ($node && !ref($node) && @$allofthem == 1)? $allofthem->[0] : $allofthem;

		# ensure that the output is indeed valid json, utf-8 encoded
		print $fh JSON::XS->new->pretty(1)->canonical(1)->convert_blessed(1)->utf8->encode( $which);
	}
	close $fh if ($fh != \*STDOUT);

	print STDERR "Successfully exported node configuration to file $file\n" if ($fh != \*STDOUT);
	exit 0;
}
elsif ($cmdline->{act} eq "show")
{
	my ($node, $uuid) = @{$cmdline}{"node","uuid"}; # uuid is safer
	my $wantquoted = NMISNG::Util::getbool($cmdline->{quoted});

	die "Cannot show node without node argument!\n\n$usage\n"
			if (!$node && !$uuid);

	my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);
	die "Node $node does not exist.\n" if (!$nodeobj);
	$node ||= $nodeobj->name;			# if  looked up via uuid

	# we want the config AND any overrides
	my $dumpables = $nodeobj->configuration;
	$dumpables->{overrides} = $nodeobj->overrides;

	my ($error, %flatearth) = NMISNG::Util::flatten_dotfields($dumpables);
	die "failed to transform output: $error\n" if ($error);
	for my $k (sort keys %flatearth)
	{
		next if ($k eq "_id");			# no use in show
		my $val = $flatearth{$k};
		# any special-ish characters to quote?
		print "$k=". ($wantquoted && $flatearth{$k} =~ /['"\$\s\(\)\{\}\[\]]/?
									"\"$flatearth{$k}\"": $flatearth{$k})."\n";
	}
	exit 0;
}
elsif ($cmdline->{act} eq "set")
{
	my ($node, $uuid) = @{$cmdline}{"node","uuid"}; # uuid is safer

	die "Cannot set node without node argument!\n\n$usage\n"
			if (!$node && !$uuid);

	my $nodeobj = $nmisng->node(uuid => $uuid, name => $node);
	die "Node $node does not exist.\n" if (!$nodeobj);
	$node ||= $nodeobj->name;			# if looked up via uuid

	my $curconfig = $nodeobj->configuration;
	my $curoverrides = $nodeobj->overrides;
	my $anythingtodo;

	for my $name (keys %$cmdline)
	{
		next if ($name !~ /^entry\./); # we want only entry.thingy, so that act= and debug= don't interfere
		++$anythingtodo;

		my $value = $cmdline->{$name};
		$name =~ s/^entry\.//;

		if ($name =~ /^overrides\.(.+)$/)
		{
			$curoverrides->{$1} = $value;
		}
		else
		{
			$curconfig->{$name} = $value;
		}
	}
	my $error = NMISNG::Util::translate_dotfields($curconfig);
	die "translation of config arguments failed: $error\n" if ($error);
	$error = NMISNG::Util::translate_dotfields($curoverrides);
	die "translation of override arguments failed: $error\n" if ($error);

	die "No changes for node \"$node\"!\n" if (!$anythingtodo);

	# check the group - only warn about
	my @knowngroups = split(/\s*,\s*/, $config->{group_list});
	if (!grep($_ eq $curconfig->{group}, @knowngroups))
	{
		print STDERR "\nWarning: your node info sets group \"$curconfig->{group}\", which does not exist!
Please adjust group_list in your configuration,
or run '".$config->{'<nmis_bin>'}."/nmis-cli act=groupsync' to add all missing groups.\n\n";
	}

	$nodeobj->overrides($curoverrides);
	$nodeobj->configuration($curconfig);

	(my $op, $error) = $nodeobj->save;
	die "Failed to save $node: $error\n" if ($op <= 0); # zero is no saving needed

	print STDERR "Successfully updated node $node.
You should run '".$config->{'<nmis_bin>'}."/poll type=update node=$node' soon.\n"
if (-t \*STDERR);								# if terminal

	exit 0;
}

elsif ($cmdline->{act} eq "delete")
{
	my ($node,$group,$confirmation,$nukedata) = @{$cmdline}{"node","group","confirm","deletedata"};

	die "Cannot delete without node or group argument!\n\n$usage\n" if (!$node and !$group);
	die "NOT deleting anything:\nplease rerun with the argument confirm='yes' in all uppercase\n\n"
			if (!$confirmation or $confirmation ne "YES");

	my $nodemodel = $nmisng->get_nodes_model(name => $node, group => $group);
	die "No matching nodes exist\n" if (!$nodemodel->count);

	my $gimmeobj = $nodemodel->objects; # instantiate, please!
	die "Failed to instantiate node objects: $gimmeobj->{error}\n"
			if (!$gimmeobj->{success});

	for my $mustdie (@{$gimmeobj->{objects}})
	{
		my ($ok, $error) = $mustdie->delete(
			keep_rrd => NMISNG::Util::getbool($nukedata, "invert")); # === eq false
		die $mustdie->name.": $error\n" if (!$ok);
	}
	exit 0;
}
elsif ($cmdline->{act} eq "rename")
{
	my ($old, $new, $uuid) = @{$cmdline}{"old","new","uuid"}; # uuid is safest for lookup

	die "Cannot rename node without old and new arguments!\n\n$usage\n"
			if ((!$old && !$uuid) || !$new);

	my $nodeobj = $nmisng->node(uuid => $uuid, name => $old);
	die "Node $old does not exist.\n" if (!$nodeobj);
	$old ||= $nodeobj->name;			# if looked up via uuid

	my ($ok, $msg) = $nodeobj->rename(new_name => $new,
																								 originator => "node_admin");
	die "$msg\n" if (!$ok);

	print STDERR "Successfully renamed node $cmdline->{old} to $cmdline->{new}.\n"
			if (-t \*STDERR);

	# any further property setting operations requested?
	if (my @todo =  grep(/^entry\..+/, keys %$cmdline))
	{
		my $curconfig = $nodeobj->configuration;
		my $curoverrides = $nodeobj->overrides;

		for my $name (@todo)
		{
			my $value = $cmdline->{$name};
			$name =~ s/^entry\.//;

			if ($name =~ /^overrides\.(.+)$/)
			{
				$curoverrides->{$1} = $value;
			}
			else
			{
				$curconfig->{$name} = $value;
			}
		}
		my $error = NMISNG::Util::translate_dotfields($curconfig);
		die "translation of config arguments failed: $error\n" if ($error);
		$error = NMISNG::Util::translate_dotfields($curoverrides);
		die "translation of override arguments failed: $error\n" if ($error);

		# check the group - only warn about
		my @knowngroups = split(/\s*,\s*/, $config->{group_list});
		if (!grep($_ eq $curconfig->{group}, @knowngroups))
		{
			print STDERR "\nWarning: your node info sets group \"$curconfig->{group}\", which does not exist!
Please adjust group_list in your configuration,
or run '".$config->{'<nmis_bin>'}."/nmis-cli act=groupsync' to add all missing groups.\n\n";
		}

		$nodeobj->overrides($curoverrides);
		$nodeobj->configuration($curconfig);

		(my $op, $error) = $nodeobj->save;
		die "Failed to save $new: $error\n" if ($op <= 0); # zero is no saving needed

		print STDERR "Successfully updated node $new.
You should run '".$config->{'<nmis_bin>'}."/poll type=update node=$new' soon.\n"
if (-t \*STDERR);								# if terminal

	}
	exit 0;
}


__END__
elsif ($cmdline{act} eq "mktemplate")
{
	# default: no placeholder
	my $wantblank = !$cmdline{placeholder};

	my @nodecomments = ( "Please see https://community.opmantek.com/display/NMIS/Home for further descriptions of the properties!", undef,
											 "name is essential and sets the node's name",
											 "host sets the primary hostname for communication (can be short name,",
											 " fully qualified name or ip address)",
											 "group is for node categorization",
											 "the above properties are REQUIRED!",undef,

											 "community defines the SNMP read community",
											 "model defines what type of device this is",
											 "active defines whether the node is enabled or disabled",
											 "collect defines whether SNMP information should be collected",
											 "ping defines whether reachability statistics should be collected",
											 "version sets the SNMP protocol version (snmpv1, snmpv2c, snmpv3)",

											 "notes is for free-form notes or comments",
											 "location provides further categorization info" );

	my $dummynode = {
		name => $wantblank? '' : "__REPLACE_NAME__",
		host => $wantblank? '' : "__REPLACE_HOST__",
		notes => $wantblank? '' : "__REPLACE_NOTES__",
		model => $wantblank? 'automatic' : "__REPLACE_MODEL__",
		group => $wantblank? '' : "__REPLACE_GROUP__",
		netType =>  $wantblank? '' : "__REPLACE_NETTYPE__",
		roleType => $wantblank? '' : "__REPLACE_ROLETYPE__",
		location => $wantblank? '' : "__REPLACE_LOCATION__",

		active => $wantblank? 'true' : "__REPLACE_ACTIVE__",
		ping => $wantblank? 'true' : "__REPLACE_PING__",
		collect => $wantblank? 'true' : "__REPLACE_COLLECT__",
		community => $wantblank? '': "__REPLACE_COMMUNITY__",
		version => $wantblank? 'snmpv2c': "__REPLACE_VERSION__",
	};

	print "// ",join("\n// ",@nodecomments),"\n\n",
	JSON::XS->new->pretty(1)->canonical(1)->utf8->encode($dummynode);

	exit 0;
}
elsif ($cmdline{act} =~ /^(create|update)$/)
{
	my ($node,$file) = @args{"node","file"};

	die "Cannot create or update node without node argument!\n\n$usage\n" if (!$node);
	die "File \"$file\" does not exist!\n" if (defined $file && $file ne "-" && ! -f $file);

	die "Invalid node name \"$node\"\n"
			if ($node =~ /[^a-zA-Z0-9_-]/);

	my $noderec = $nodeinfo->{$node};
	die "Node $node does not exist.\n" if (!$noderec && $cmdline{act} eq "update");
	die "Node $node already exist.\n" if ($noderec && $cmdline{act} eq "create");

	print STDERR "Reading node configuration data for $node\n" if ($debuglevel or $infolevel);
	# suck in the data
	my $fh;
	if (!$file or $file eq "-")
	{
		$fh = \*STDIN;
	}
	else
	{
			 open($fh,"$file") or die "cannot read from $file: $!\n";
	}
	my $nodedata = join('', grep( !m!^\s*//\s+!, <$fh>));
	close $fh if ($fh != \*STDIN);

	# sanity check this first!
	die "Invalid node data, __REPLACE_... placeholders are still present!\n"
			if ($nodedata =~ /__REPLACE_\S+__/);

	print STDERR "Parsing JSON node configuration data\n" if ($debuglevel or $infolevel);
	my $mayberec;
	# check correct encoding (utf-8) first, fall back to latin-1
	$mayberec = eval { decode_json($nodedata); };
	$mayberec = eval { JSON::XS->new->latin1(1)->decode($nodedata); } if ($@);

	die "Invalid node data, JSON parsing failed: $@\n" if ($@);

	die "Invalid node data, name value \"$mayberec->{name}\" does not match argument \"$node\".
Use act=rename for renaming nodes.\n"
			if ($mayberec->{name} ne $node);


	die "Invalid node data, not a hash!\n" if (ref($mayberec) ne 'HASH');
	die "Invalid node data, does not have required attributes name, host and group\n"
			if (!$mayberec->{name} or !$mayberec->{host} or !$mayberec->{group});

	die "Invalid node data, netType \"$mayberec->{netType}\" is not known!\n"
			if (!grep($mayberec->{netType} eq $_, split(/\s*,\s*/, $config->{nettype_list})));
	die "Invalid node data, roleType \"$mayberec->{roleType}\" is not known!\n"
			if (!grep($mayberec->{roleType} eq $_, split(/\s*,\s*/, $config->{roletype_list})));

	# no uuid? then we add one
	if (!$mayberec->{uuid})
	{
		$mayberec->{uuid} = Compat::UUID::getUUID($node);
	}

	# ok, looks good enough. save the node info.
	print STDERR "Saving node $node in Nodes table\n" if ($debuglevel or $infolevel);
	$nodeinfo->{$node} = $mayberec;
	# fixme lowprio: if db_nodes_sql is enabled we need to use a different write function
	NMISNG::Util::writeTable(dir => 'conf', name => "Nodes", data => $nodeinfo);

	# nix any pending events
	if ($cmdline{act} eq "update")
	{
		print STDERR "Removing events for node $node\n" if ($debuglevel or $infolevel);
		Compat::NMIS::cleanEvent($node,"node-admin");
	}

	# check the group
	my @knowngroups = split(/\s*,\s*/, $config->{group_list});
	if (!grep($_ eq $mayberec->{group}, @knowngroups))
	{
		print STDERR "\nWarning: your node info sets group \"$mayberec->{group}\", which does not exist!
Please adjust group_list in your configuration,
or run '".$config->{'<nmis_bin>'}."/nmis.pl type=groupsync' to add all missing groups.\n\n";
	}

	print STDERR "Successfully $cmdline{act}d node $node.
You should run '".$config->{'<nmis_bin>'}."/nmis.pl type=update node=$node' soon.\n";
	exit 0;
}
else
{
	# fallback: complain about the arguments
	die "Could not parse arguments!\n\n$usage\n";
}

exit 0;
