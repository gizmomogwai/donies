module app;

import argparse : Command, NamedArgument, PositionalArgument, SubCommand, CLI,
    Description, Required, matchCmd, EnvFallback;
import asciitable : AsciiTable;
import colored : bold, cyan, darkGray, lightGreen, lightRed;
import core.atomic : atomicLoad, atomicStore;
import core.thread : msecs, Thread;
import progressbar : Progressbar, MultiProgressbarTextUI, textUi;
import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.file : getSize;
import std.parallelism : parallel;
import std.path : baseName, stripExtension;
import std.stdio : stderr, writefln, writeln;
import std.string : format;
import unit : mostSignificant, onlyRelevant, TIME;
import api : Household, CreativeTonie, NewChapter, authenticate, getHouseholds,
    getCreativeTonies, clearChapters, requestUploadUrl, uploadToS3, setChapters, urlFor;

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
    @(NamedArgument(["email"]).Description("Tonie account email")
            .Required.EnvFallback("TONIES_EMAIL"))
    string email;

    @(NamedArgument(["password"]).Description("Tonie account password")
            .Required.EnvFallback("TONIES_PASSWORD"))
    string password;

    SubCommand!(List, Clear, Upload) cmd;
}

private void heading(string msg)
{
    writeln(("==> " ~ msg).cyan.bold.to!string);
}

private void detail(string msg)
{
    writeln("  " ~ msg);
}

private void success(string msg)
{
    writeln(("  ✓ " ~ msg).lightGreen.to!string);
}

private void fail(string msg)
{
    stderr.writeln(("  ✗ " ~ msg).lightRed.bold.to!string);
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

    throw new Exception(format!("Household '%s' not found. Available: %-(%s, %)")(name,
            households));
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
    throw new Exception(format!("Creative Tonie '%s' not found. Available: %-(%s, %)")(name,
            tonies));
}

private string formatSeconds(double seconds)
{
    auto parts = TIME.transform(cast(long)(seconds * 1000))
        .onlyRelevant.mostSignificant(2).map!(p => format!("%d%s")(p.value, p.name)).join(" ");
    return parts.length > 0 ? parts : "0s";
}

private int runList(string token)
{
    heading("Fetching households ...");
    auto households = getHouseholds(token);

    // dfmt off
    auto table = new AsciiTable(8)
        .header.add("Household")
        .add("Household-ID")
            .add("Tonie")
            .add("Tonie-ID")
            .add("Chapters")
            .add("Duration")
            .add("Remaining")
            .add("URL")
        ;
    // dfmt on

    foreach (household; households)
    {
        auto tonies = getCreativeTonies(token, household.id);
        foreach (tonie; tonies)
        {
            // dfmt off
            table.row.add(household.name)
                .add(household.id)
                .add(tonie.name)
                .add(tonie.id)
                .add(format("%s / %s", tonie.chaptersPresent, tonie.chaptersRemaining + tonie.chaptersPresent))
                .add(format("%s / %s", formatSeconds(tonie.secondsPresent), formatSeconds(tonie.secondsRemaining + tonie.secondsPresent)))
                .add(formatSeconds(tonie.secondsRemaining))
                .add(urlFor(household, tonie))
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

    heading(format!("Clearing all chapters from '%s' ...")(tonie.name));
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

    heading(format!("Uploading %d file(s) in parallel ...")(cmd.files.length));

    auto pbs = new Progressbar[cmd.files.length];
    foreach (i, file; cmd.files)
        pbs[i] = new Progressbar(getSize(file));

    auto pbFormat = "  %<120m [%=10P] %p";

    auto mpb = new MultiProgressbarTextUI(pbs.map!(pb => textUi(pb, pbFormat)).array);

    foreach (i, file; cmd.files)
    {
        pbs[i].message(format!("idle - %s")(stripExtension(baseName(file))));
    }

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
        pbs[i].message(format!("url  - %s")(title));
        auto uploadReq = requestUploadUrl(token);
        pbs[i].message(format!("s3   - %s")(title));
        uploadToS3(uploadReq, file, (size_t n) { pbs[i].step(n); });
        pbs[i].message(format!("✓    - %s")(title));
        results[i] = NewChapter(title, uploadReq.fileId);
    }

    atomicStore(stopRender, true);
    renderThread.join();
    mpb.finish();

    heading(format!("Setting %d chapter(s) on '%s' ...")(results.length, tonie.name));
    setChapters(token, household.id, tonie.id, results);
    success(format!("%d chapter(s) committed to tonie. %s")(results.length,
            urlFor(household, tonie)));
    return 0;
}

mixin CLI!Arguments.main!((arguments) {
    try
    {
        heading(format!("Authenticating as %s ...")(arguments.email));
        string token = authenticate(arguments.email, arguments.password);
        success("Authenticated.");

        // dfmt off
        return arguments.cmd.matchCmd!(
            (List _) => runList(token),
            (Clear cmd) => runClear(token, cmd),
            (Upload cmd) => runUpload(token, cmd)
        );
        // dfmt on
    }
    catch (Exception e)
    {
        fail(e.msg);
        return 1;
    }
});
