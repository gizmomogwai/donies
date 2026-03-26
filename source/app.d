module app;

import argparse : Command, NamedArgument, PositionalArgument, SubCommand, CLI,
    Description, Required, matchCmd;
import asciitable : AsciiTable;
import colored : bold, cyan, darkGray, lightGreen, lightRed;
import core.atomic : atomicLoad, atomicStore;
import core.thread : msecs, Thread;
import progressbar : multiTextUi, Progressbar;
import std.algorithm : map;
import std.array : join;
import std.conv : to;
import std.file : getSize;
import std.parallelism : parallel;
import std.path : baseName, stripExtension;
import std.stdio : stderr, writefln, writeln;
import std.string : format;
import unit : mostSignificant, onlyRelevant, TIME;
import api : Household, CreativeTonie, NewChapter, authenticate, getHouseholds,
    getCreativeTonies, clearChapters, requestUploadUrl, uploadToS3, setChapters;

@(Command("list").Description("List all households and their Creative Tonies"))
struct List
{
}

@(Command("clear").Description("Clear all chapters from a Creative Tonie"))
struct Clear
{
    @(NamedArgument("tonie").Description("Name of the Creative Tonie to clear").Required)
    string tonie;

    @(NamedArgument("household").Description("Name of the household (default: first household)"))
    string household;
}

@(Command("upload").Description("Upload audio files to a Creative Tonie"))
struct Upload
{
    @(NamedArgument("tonie").Description("Name of the Creative Tonie to upload to").Required)
    string tonie;

    @(NamedArgument("household").Description("Name of the household (default: first household)"))
    string household;

    @(PositionalArgument(0).Description("Audio files to upload"))
    string[] files;
}

@(Command("donie").Description("Manage Creative Tonies via the Tonie Cloud API"))
struct Arguments
{
    @(NamedArgument(["email", "e"]).Description("Tonie account email").Required)
    string email;

    @(NamedArgument(["password", "p"]).Description("Tonie account password").Required)
    string password;

    SubCommand!(List, Clear, Upload) cmd;
}

private void heading(string msg)
{
    writeln(("==> " ~ msg).cyan.bold.to!string);
}

private void detail(string msg)
{
    writeln("    " ~ msg);
}

private void success(string msg)
{
    writeln(("    ✓ " ~ msg).lightGreen.to!string);
}

/// Red error line with a cross.
private void fail(string msg)
{
    stderr.writeln(("    ✗ " ~ msg).lightRed.bold.to!string);
}

private Household resolveHousehold(Household[] households, string name)
{
    if (name is null)
    {
        return households[0];
    }

    foreach (h; households)
    {
        if (h.name == name)
        {
            return h;
        }
    }

    throw new Exception(format!"Household '%s' not found. Available: %-(%s, %)"(name, households));
}

private CreativeTonie resolveTonie(CreativeTonie[] tonies, string name)
{
    foreach (t; tonies)
    {
        if (t.name == name)
        {
            return t;
        }
    }
    throw new Exception(format!"Creative Tonie '%s' not found. Available: %-(%s, %)"(name, tonies));
}

private string formatSeconds(double seconds)
{
    auto parts = TIME.transform(cast(long)(seconds * 1000)).onlyRelevant.mostSignificant(2)
        .map!(p => format!"%d%s"(p.value, p.name)).join(" ");
    return parts.length > 0 ? parts : "0s";
}

private int runList(string token)
{
    heading("Fetching households ...");
    auto households = getHouseholds(token);

    // dfmt off
    auto table = new AsciiTable(6)
        .header.add("Household")
            .add("Tonie")
            .add("ID")
            .add("Chapters")
            .add("Duration")
            .add("Remaining");
    // dfmt on

    foreach (h; households)
    {
        auto tonies = getCreativeTonies(token, h.id);
        foreach (t; tonies)
        {
            // dfmt off
            table.row.add(h.name)
                .add(t.name)
                .add(t.id)
                .add(format("%s / %s", t.chaptersPresent, t.chaptersRemaining + t.chaptersPresent))
                .add(format("%s / %s", formatSeconds(t.secondsPresent), formatSeconds(t.secondsRemaining + t.secondsPresent)))
                .add(formatSeconds(t.secondsRemaining))
            ;
            // dfmt on
        }
    }

    table.format.columnSeparator(true).headerSeparator(true).writeln;

    return 0;
}

private int runClear(string token, Clear cmd)
{
    auto households = getHouseholds(token);
    auto household = resolveHousehold(households, cmd.household);
    auto tonies = getCreativeTonies(token, household.id);
    auto tonie = resolveTonie(tonies, cmd.tonie);

    heading(format!"Clearing all chapters from '%s' ..."(tonie.name));
    clearChapters(token, household.id, tonie.id);
    success("All chapters cleared.");
    return 0;
}

private int runUpload(string token, Upload cmd)
{
    if (cmd.files.length == 0)
    {
        fail("No files specified for upload.");
        return 1;
    }

    auto households = getHouseholds(token);
    auto household = resolveHousehold(households, cmd.household);
    auto tonies = getCreativeTonies(token, household.id);
    auto tonie = resolveTonie(tonies, cmd.tonie);

    heading(format!"Uploading %d file(s) in parallel ..."(cmd.files.length));

    auto pbs = new Progressbar[cmd.files.length];
    foreach (i, file; cmd.files)
        pbs[i] = new Progressbar(getSize(file));

    auto fmts = new string[cmd.files.length];
    fmts[] = " %<25m [%=30P] %p";

    auto mpb = multiTextUi(pbs, fmts);

    foreach (i, file; cmd.files)
        pbs[i].message(stripExtension(baseName(file)));

    shared bool stopRender = false;
    auto renderThread = new Thread({
        while (!atomicLoad(stopRender))
        {
            mpb.render();
            Thread.sleep(100.msecs);
        }
        mpb.render();
    }).start();

    auto results = new NewChapter[cmd.files.length];
    foreach (i, file; parallel(cmd.files))
    {
        string title = stripExtension(baseName(file));
        pbs[i].message("url - " ~ title);
        auto uploadReq = requestUploadUrl(token);
        pbs[i].message("s3  - " ~ title);
        uploadToS3(uploadReq, file, (size_t n) { pbs[i].step(n); });
        pbs[i].message(" ✓  - " ~ title);
        results[i] = NewChapter(title, uploadReq.fileId);
    }

    atomicStore(stopRender, true);
    renderThread.join();
    mpb.finish();

    heading(format!"Setting %d chapter(s) on '%s' ..."(results.length, tonie.name));
    setChapters(token, household.id, tonie.id, results);
    success(format!"%d chapter(s) committed to tonie."(results.length));
    return 0;
}

mixin CLI!Arguments.main!((arguments) {
    try
    {
        heading(format!"Authenticating as %s ..."(arguments.email));
        string token = authenticate(arguments.email, arguments.password);
        success("Authenticated.");

        return arguments.cmd.matchCmd!((List _) => runList(token),
            (Clear cmd) => runClear(token, cmd), (Upload cmd) => runUpload(token, cmd));
    }
    catch (Exception e)
    {
        fail(e.msg);
        return 1;
    }
});
