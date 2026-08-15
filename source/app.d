module app;

import argparse : Command, NamedArgument, PositionalArgument, SubCommand, CLI,
    Description, Required, matchCmd, EnvFallback;
import asciitable : AsciiTable;
import colored : bold, cyan, darkGray, lightGreen, lightRed;
import core.thread : msecs;
import progressbar : compositeUi, graphicalTerminalUi, MultiLineProgressbarUI, Progressbar, textUi;
import std.algorithm : map;
import std.array : array, join;
import std.concurrency : Tid, receiveOnly, receiveTimeout, send, spawn, thisTid;
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

private enum HIDE_CURSOR = "\033[?25l";
private enum SHOW_CURSOR = "\033[?25h";

private enum UploadStage
{
    idle,
    requestUrl,
    uploadS3,
    done
}

private struct ProgressBytesUpdate
{
    size_t index;
    size_t bytes;
}

private struct ProgressStageUpdate
{
    size_t index;
    UploadStage stage;
}

private struct StopRendering
{
}

private struct RenderingStopped
{
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

private void setCursorVisible(bool visible)
{
    stderr.write(visible ? SHOW_CURSOR : HIDE_CURSOR);
    stderr.flush();
}

private string uploadProgressMessage(UploadStage stage, string title)
{
    final switch (stage)
    {
    case UploadStage.idle:
        return format!("idle - %s")(title);
    case UploadStage.requestUrl:
        return format!("url  - %s")(title);
    case UploadStage.uploadS3:
        return format!("s3   - %s")(title);
    case UploadStage.done:
        return format!("✓    - %s")(title);
    }
}

private void renderUploadProgress(Tid ownerTid, immutable(string)[] titles,
        immutable(size_t)[] fileSizes, size_t totalBytes)
{
    auto pbs = new Progressbar[fileSizes.length];
    foreach (i, fileSize; fileSizes)
    {
        pbs[i] = new Progressbar(fileSize);
        pbs[i].message(uploadProgressMessage(UploadStage.idle, titles[i]));
    }

    auto pbFormat = "  %<120m [%=10P] %p";
    auto totalProgressbar = new Progressbar(totalBytes);
    auto ui = compositeUi(new MultiLineProgressbarUI(pbs.map!(pb => textUi(pb, pbFormat)).array),
            graphicalTerminalUi(totalProgressbar));
    auto completed = new bool[fileSizes.length];

    size_t completedFiles;
    size_t uploadedBytes;
    bool stopRequested;

    scope (exit)
    {
        ui.finish();
        ownerTid.send(RenderingStopped());
    }

    while (!stopRequested || completedFiles < fileSizes.length || uploadedBytes < totalBytes)
    {
        receiveTimeout(100.msecs,
                (ProgressBytesUpdate msg) {
            pbs[msg.index].step(msg.bytes);
            totalProgressbar.step(msg.bytes);
            uploadedBytes += msg.bytes;
        },
                (ProgressStageUpdate msg) {
            pbs[msg.index].message(uploadProgressMessage(msg.stage, titles[msg.index]));
            if (msg.stage == UploadStage.done && !completed[msg.index])
            {
                completed[msg.index] = true;
                completedFiles++;
            }
        },
                (StopRendering _) {
            stopRequested = true;
        });

        ui.render();
    }

    ui.render();
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

    auto titles = new string[cmd.files.length];
    auto fileSizes = new size_t[cmd.files.length];
    size_t totalBytes;
    foreach (i, file; cmd.files)
    {
        auto fileSize = getSize(file);
        fileSizes[i] = fileSize;
        titles[i] = stripExtension(baseName(file));
        totalBytes += fileSize;
    }

    auto results = new NewChapter[cmd.files.length];
    {
        auto renderTitles = cast(immutable) titles.map!(title => cast(immutable) title.dup).array;
        auto renderFileSizes = cast(immutable) fileSizes.dup;
        auto renderThread = spawn(&renderUploadProgress, thisTid, renderTitles, renderFileSizes,
                totalBytes);

        setCursorVisible(false);
        scope (exit)
        {
            renderThread.send(StopRendering());
            receiveOnly!RenderingStopped();
            setCursorVisible(true);
        }

        foreach (i, file; parallel(cmd.files))
        {
            auto index = cast(size_t) i;
            auto title = titles[index];
            renderThread.send(ProgressStageUpdate(index, UploadStage.requestUrl));
            auto uploadReq = requestUploadUrl(token);
            renderThread.send(ProgressStageUpdate(index, UploadStage.uploadS3));
            uploadToS3(uploadReq, file, (size_t n) {
                renderThread.send(ProgressBytesUpdate(index, n));
            });
            renderThread.send(ProgressStageUpdate(index, UploadStage.done));
            results[index] = NewChapter(title, uploadReq.fileId);
        }
    }

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
