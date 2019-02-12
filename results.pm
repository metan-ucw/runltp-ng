#!/usr/bin/env perl
#
# Linux Test Project test runner
#
# Copyright (c) 2017-2018 Cyril Hrubis <chrubis@suse.cz>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

package results;

sub json_print_string
{
	my ($fh, $str) = @_;

	$str =~ s/\\/\\\\/g;
	$str =~ s/"/\\"/g;
	$str =~ s/[^[:print:]]//g;

	print($fh '"' . $str . '"');
}

sub writelog_json
{
	my ($log, $fh, $padd) = @_;

	$padd = '' unless defined($padd);

	print($fh "\{\n");

	my @keys = keys(%$log);

	for my $i (0 .. $#keys) {
		my $key = $keys[$i];
		my $val = $log->{$key};
		my $type = ref($val);
		my $lpadd = $padd . '  ';

		print($fh "$lpadd\"$key\": ");

		if ($type eq 'HASH') {
			writelog_json($val, $fh, $lpadd);
		}

		if ($type eq 'ARRAY') {
			print($fh "\[\n");
			for my $j (0 .. $#{$val}) {
				my $ipadd = $lpadd . '  ';
				my $aval = $val->[$j];

				print($fh "$ipadd");
				if (ref($aval) eq '') {
					json_print_string($fh, $aval);
				} else {
					writelog_json($aval, $fh, $ipadd);
				}
				print($fh ",") if ($j < $#{$val});
				print($fh "\n");
			}
			print($fh "${lpadd}]");
		}

		if ($type eq '') {
			if ($val =~ m/^\d+$/) {
				print($fh "$val");
			} else {
				json_print_string($fh, $val);
			}
		}

		print($fh ",") if ($i < $#keys);
		print($fh "\n");
	}

	print($fh "$padd\}");
	print("\n") if ($padd eq '');
}

my $html_header = "<html>
 <head>
  <meta charset=\"UTF-8\">
  <title>LTP results</title>
  <style>
   body {
    background-color: #eee;
    font: 80% \"Helvetica\";
    text-align: center;
   }
   table {border-collapse: collapse;}
   th, td {
    border-bottom: 1px solid #888;
    text-align: right;
    padding-top: 0.1em;
    padding-bottom: 0.1em;
    padding-left: 0.5em;
    padding-right: 0.5em;
   }
   th {
       border-top: 1px solid #888;
       background-color: #ccc;
   }
   tr {
       border-left: 1px solid #888;
       border-right: 1px solid #888;
   }
   hr {border-top: 1px solid #888; border-bottom: 0px;}
   td:hover.rtime {background-color: #ccf}
   td:hover.pass {background-color: #9f9}
   td:hover.fail {background-color: #f99}
   td:hover.brok {background-color: #f99}
   td:hover.skip {background-color: #ff9}
   td:hover.warn {background-color: #f9f}
   td.rtime {background-color: #aaf; text-align: center;}
   td.pass {background-color: #7f7; text-align: center;}
   td.fail {background-color: #f77; text-align: center;}
   td.brok {background-color: #f77; text-align: center;}
   td.skip {background-color: #ff7; text-align: center;}
   td.warn {background-color: #f7f; text-align: center;}
   th.id, td.id {text-align: left; width: 15em;}
   th:hover {background-color: #bbb}
   tr:hover.info {background-color: #eee}
   tr:hover.pass {background-color: #9f9}
   tr:hover.fail {background-color: #f99}
   tr:hover.brok {background-color: #f99}
   tr:hover.skip {background-color: #ff9}
   tr:hover.warn {background-color: #f9f}
   tr.info {background-color: #ddd; text-align: left;}
   tr.pass {background-color: #7f7}
   tr.fail {background-color: #f77}
   tr.brok {background-color: #f77}
   tr.skip {background-color: #ff7}
   tr.warn {background-color: #f7f}
   tr.hidden1 {display: none}
   tr.hidden2 {display: none}
   tr.hidden3 {display: none}
   tr.logs {background-color: #bbb;}
   tr:hover.logs {background-color: #ccc;}
   td.logs {text-align: left}
   table.hidden {display: none}
  </style>
  <script type=\"text/javascript\">
   function toggle_visibility(element, class_id) {
       var table = document.getElementById(\"results\");
       table.classList.add(\"hidden\");
       if (element.checked) {
           for (var i = 1; table.rows[i]; i+=2) {
               if (table.rows[i].classList.contains(class_id)) {
                   table.rows[i].classList.add(\"hidden1\");
                   table.rows[i+1].classList.add(\"hidden1\");
               }
           }
       } else {
           for (var i = 1; table.rows[i]; i+=2) {
               if (table.rows[i].classList.contains(class_id)) {
                   table.rows[i].classList.remove(\"hidden1\");
                   table.rows[i+1].classList.remove(\"hidden1\");
               }
           }
       }
       table.classList.remove(\"hidden\");
   }
   function filter_by_id(substr) {
       var table = document.getElementById(\"results\");
       table.classList.add(\"hidden\");
       for (var i = 1; table.rows[i]; i+=2) {
           if (table.rows[i].cells[0].innerText.includes(substr)) {
               table.rows[i].classList.remove(\"hidden2\");
               table.rows[i+1].classList.remove(\"hidden2\");
           } else {
               table.rows[i].classList.add(\"hidden2\");
               table.rows[i+1].classList.add(\"hidden2\");
           }
       }
       table.classList.remove(\"hidden\");
   }
   function str2s(str) {
       var f = str.split(' ');
       if (f.length > 1)
           return parseInt(f[0]) * 60 + parseFloat(f[1]);
       return parseFloat(f[0]);
   }
   function cmp_asc(row1, row2, cell_id) {
       var h1 = row1.cells[cell_id].innerHTML;
       var h2 = row2.cells[cell_id].innerHTML;
       if (cell_id != 2) return h1 < h2
       return str2s(h1) < str2s(h2);
   }
   function cmp_desc(row1, row2, cell_id) {
       var h1 = row1.cells[cell_id].innerHTML;
       var h2 = row2.cells[cell_id].innerHTML;
       if (cell_id != 2) return h1 > h2
       return str2s(h1) > str2s(h2);
   }
   function sort(cmp, cell_id) {
       var table = document.getElementById(\"results\");
       table.classList.add(\"hidden\");
       for (var i = 3; table.rows[i]; i+=2) {
           var l = 1, r = i, m;
           while (r - l > 2) {
               /* Find odd table row in the middle */
               m = (r - l)/2 + l + ((((r - l)/2) % 2) ? 1 : 0);
               if (cmp(table.rows[i], table.rows[m], cell_id))
                   r = m;
               else
                   l = m;
           }
           m = cmp(table.rows[l], table.rows[i], cell_id) ? r : l;
           if (i == m)
               continue;
           var rowi1 = table.rows[i];
           var rowi2 = table.rows[i+1];
           var row = table.rows[m];
           rowi1.parentNode.insertBefore(rowi1, row);
           rowi2.parentNode.insertBefore(rowi2, row);
       }
       table.classList.remove(\"hidden\");
   }
   function sort_by(cell_id) {
       var table = document.getElementById(\"results\");
       var id_col = table.rows[0].cells[cell_id].innerHTML;
       if (id_col.endsWith(\"\\u2191\")) {
           sort(cmp_desc, cell_id);
           table.rows[0].cells[cell_id].innerHTML = id_col.slice(0, -1) + \"\\u2193\";
       } else {
           sort(cmp_asc, cell_id);
           table.rows[0].cells[cell_id].innerHTML = id_col.slice(0, -1) + \"\\u2191\";
       }
   }
  </script>
 </head>
 <body>
  <div style=\"display: inline-block\">
   <center>
   <h1>LTP Results</h1>";


my $html_footer="</center>
  </div>
  <script type=\"text/javascript\">
   var table = document.getElementById(\"results\");
   for (var i = 1; table.rows[i]; i++) {
       table.rows[i].onclick = function() {
           if (this.classList.contains(\"logs\")) {
               this.classList.add(\"hidden3\");
           } else {
               var next_row = this.parentNode.rows[this.rowIndex + 1];
               if (next_row.classList.contains(\"hidden3\"))
                   next_row.classList.remove(\"hidden3\");
               else
                   next_row.classList.add(\"hidden3\");
           }
       }
   }
  </script>
 </body>
</html>";

sub write_sysinfo
{
	my ($fh, $sysinfo) = @_;

	return unless defined($sysinfo);

	print($fh "   <table width=\"100%\">\n");
	print($fh "    <tr>\n");
	print($fh "     <th colspan=\"2\" style=\"text-align: center\">System information</th>\n");
	print($fh "    </tr>\n");

	for (keys %$sysinfo) {
		my $val = $sysinfo->{$_};

		print($fh "    <tr class=\"info\">\n");
		print($fh "     <td>$_:</td>\n");
		print($fh "     <td>$val</td>\n");
		print($fh "    </tr>\n");
	}

	print($fh "   </table>\n");
}

sub write_runtime
{
	my ($fh, $runtime) = @_;
	my $min = 0;

	if ($runtime / 60 >= 1) {
		use integer;
		$min = $runtime/60;
		print($fh "${min}m ");
	}

	$runtime -= 60 * $min;

	printf($fh "%.2fs", $runtime);
}

sub write_stats
{
	my ($fh, $stats) = @_;

	return unless defined($stats);

	print($fh "   <table width=\"100%\">\n");
	print($fh "    <tr>\n");
	print($fh "     <th colspan=\"6\" style=\"text-align: center\">Overall results</th>\n");
	print($fh "    </tr>\n");
        print($fh "    <tr>\n");
	print($fh "     <td class=\"rtime\">Runtime: ");
	write_runtime($fh, $stats->{'runtime'});
        print($fh "</td>\n");
	print($fh "     <td class=\"pass\">Passed: $stats->{'passed'}</td>\n");
	print($fh "     <td class=\"skip\">Skipped: $stats->{'skipped'}</td>\n");
	print($fh "     <td class=\"fail\">Failed: $stats->{'failed'}</td>\n");
	print($fh "     <td class=\"brok\">Broken: $stats->{'broken'}</td>\n");
	print($fh "     <td class=\"warn\">Warnings: $stats->{'warnings'}</td>\n");
	print($fh "    </tr>\n");
	print($fh "   </table>\n");
}

sub html_escape
{
	my ($line) = @_;

	$line =~ s/&/&amp;/g;
	$line =~ s/>/&gt;/g;
	$line =~ s/</&lt;/g;

	return $line;
}

sub write_results
{
	my ($fh, $results) = @_;

	print($fh "    <div style=\"background-color: #ccc\">\n");
	print($fh "     <hr>\n");
	print($fh "     <input type=\"checkbox\" onchange=\"toggle_visibility(this, 'pass')\"> Hide Passed\n");
	print($fh "     <input type=\"checkbox\" onchange=\"toggle_visibility(this, 'skip')\"> Hide Skipped\n");
	print($fh "     Filter by ID: <input type=\"text\" onkeyup=\"filter_by_id(this.value)\">\n");
	print($fh "     <hr>\n");
	print($fh "    </div>\n");

	printf($fh "    <table id=\"results\" style=\"cursor: pointer\">\n");
	printf($fh "     <tr>\n");
        printf($fh "      <th onclick=\"sort_by(0)\" class=\"id\">Test ID &#8597;</th>\n");
	printf($fh "      <th onclick=\"sort_by(1)\">Runs &#8597;</th>\n");
	printf($fh "      <th onclick=\"sort_by(2)\">Runtime &#8597;</th>\n");
	printf($fh "      <th onclick=\"sort_by(3)\">Passes &#8597;</th>\n");
	printf($fh "      <th onclick=\"sort_by(4)\">Skips &#8597;</th>\n");
	printf($fh "      <th onclick=\"sort_by(5)\">Fails &#8597;</th>\n");
	printf($fh "      <th onclick=\"sort_by(6)\">Broken &#8597;</th>\n");
	printf($fh "      <th onclick=\"sort_by(7)\">Warns &#8597;</th>\n");
	printf($fh "     </tr>\n");

	for (@$results) {
		my $class;

		if ($_->{'failed'}) {
			$class = 'fail';
		} elsif ($_->{'broken'}) {
			$class = 'brok';
		} elsif ($_->{'warnings'}) {
			$class = 'warn';
		} elsif ($_->{'skipped'}) {
			$class = 'skip';
		} else {
			$class = 'pass';
		}

		print($fh "     <tr class=\"$class\">\n");
		print($fh "      <td class=\"id\">$_->{'tid'}</td>\n");

		# TODO!
		print($fh "      <td>$_->{'runs'}</td>\n");

		print($fh "      <td>");
		write_runtime($fh, $_->{'runtime'});
                print($fh "</td>\n");

		print($fh "      <td>$_->{'passed'}</td>\n");
		print($fh "      <td>$_->{'skipped'}</td>\n");
		print($fh "      <td>$_->{'failed'}</td>\n");
		print($fh "      <td>$_->{'broken'}</td>\n");
		print($fh "      <td>$_->{'warnings'}</td>\n");
		print($fh "     </tr>\n");
                print($fh "     <tr class=\"logs hidden3\">\n");
                print($fh "      <td class=\"logs\" colspan=\"8\">\n");
		print($fh "       <pre>\n");
		print($fh html_escape($_) . "\n") for (@{$_->{'log'}});
		print($fh "       </pre>\n");
                print($fh "      </td>\n");
		print($fh "     </tr>\n");
	}
}

sub writelog_html
{
	my ($log, $fname) = @_;

	open(my $fh, ">", $fname) or die "Can't open $fname: $!";

	print($fh $html_header);
	write_sysinfo($fh, $log->{'sysinfo'});

	my $test = $log->{'tests'};

	print($fh "   <br>\n");

	write_stats($fh, $test->{'stats'});
	write_results($fh, $test->{'results'});

	print($fh $html_footer);

	close($fh);
}

sub writelog
{
	my ($log, $fname) = @_;

	open(my $fh, ">", $fname) or die "Can't open $fname: $!";

	writelog_json($log, $fh);

	close($fh);
}

1;
