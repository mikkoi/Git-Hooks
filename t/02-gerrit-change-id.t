my $gerrit_script = catfile($T, 'gerrit-commit-msg');
    write_file($gerrit_script, {err_mode => 'carp'}, <DATA>)
        or BAIL_OUT("can't write_file('$gerrit_script', <DATA>)\n");
    write_file($msgfile, {err_mode => 'carp'}, $msg)
        or BAIL_OUT("cannot_commit: can't write_file('$msgfile', '$msg')\n");
    write_file($msgfile, {err_mode => 'carp'}, $msg)
        or BAIL_OUT("can_commit: can't write_file('$msgfile', '$msg')\n");
    write_file($msgfile, {err_mode => 'carp'}, $msg)
        or BAIL_OUT("check_can_commit: can't write_file('$msgfile', '$msg')\n");
    system('sh', $gerrit_script, $msgfile);
    write_file($msgfile, {err_mode => 'carp'}, $msg)
        or BAIL_OUT("check_can_commit: can't write_file('$msgfile', '$msg')\n");
    $expected =~ s/\bI[0-9a-f]{40}\b/I0000000000000000000000000000000000000000/;
    $produced =~ s/\bI[0-9a-f]{40}\b/I0000000000000000000000000000000000000000/;
    [ 'no-CID',              "\n" ],
    [ 'single-line',         "\n\n$CID\n" ],
    [ 'multi-line',          "\n\nb\n\nc\n\n$CID\n" ],
    [ 'not-a-footer',        "\n\nb: not a footer\nc\nd\ne\n\nf\ng\nh\n\n$CID\n" ],
    [ 'single-line SOB',     "\n\n$CID\n$SOB1\n" ],
    [ 'multi-line SOB',      "\n\nb\n\nc\n\n$CID\n$SOB1\n" ],
    [ 'not-a-footer SOB',    "\n\nb: not a footer\nc\nd\ne\n\nf\ng\nh\n\n$CID\n$SOB1\n" ],
    [ 'note-in-middle',      "\n\nNOTE: This\ndoes not fix it.\n\n$CID\n" ],
    [ 'kernel-style-footer', "\n\n$CID\n$SOB1\n[ja: Fixed\n     the indentation]\n$SOB2\n" ],
    [ 'CID-after-Bug',       "\n\nBug: 42\n$CID\n$SOB1\n" ],
    [ 'CID-after-Issue',     "\n\nIssue: 42\n$CID\n$SOB1\n" ],
    [ 'commit-dashv',        "\n\n$SOB1\n$SOB2\n\n# on branch master\ndiff --git a/src b/src\nnew file mode 100644\nindex 0000000..c78b7f0\n" ],
    [ 'with-url http',       "\n\nhttp://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url https',      "\n\nhttps://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url ftp',        "\n\nftp://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url git',        "\n\ngit://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-false-tags',     "\n\nFakeLine:\n  foo\n  bar\n\n$CID\nRealTag: abc\n" ],
    my $msg = join('', @$test);
    my $expected = expected($msg);
    my $produced = produced($msg);