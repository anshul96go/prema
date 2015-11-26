/** Data Model and Persistence **/

import d2sqlite3;
import std.algorithm : findSplitBefore, sort;
import std.stdio : writeln;
import std.math : log, exp, isNaN, abs;
import std.conv : text, to;
import std.format : formatValue, singleSpec, formattedWrite;
import std.datetime : Clock, SysTime, dur;
import std.exception : enforce;
import std.file : exists;

enum share_type
{
    init = 0,
    yes = 1,
    no = 2,
    balance = 3,
}

share_type fromInt(int n)
{
    switch (n)
    {
    case 1:
        return share_type.yes;
    case 2:
        return share_type.no;
    default:
        return share_type.balance;
    }
}

/** All money is represented as millicredits **/
struct millicredits
{
    long amount;
    bool opEquals()(auto ref const millicredits s) const
    {
        return amount == s.amount;
    }

    int opCmp(ref const millicredits s) const
    {
        if (amount < s.amount)
            return -1;
        else if (amount > s.amount)
            return 1;
        else
            return 0;
    }

    millicredits opBinary(string op)(ref const millicredits rhs) const
    {
        static if (op == "+")
            return millicredits(amount + rhs.amount);
        else static if (op == "-")
            return millicredits(amount - rhs.amount);
        else
            static assert(0, "Operator " ~ op ~ " not implemented");
    }

    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink.formattedWrite("%.3f", amount / 1000.0);
        sink("¢");
    }
}

millicredits credits(real x)
{
    return millicredits(to!long(x * 1000.0));
}

const MARKETS_ID = 1;
const FUNDER_ID = 2;

void init_empty_db(Database db)
{
    db.execute("CREATE TABLE users (
		id INTEGER PRIMARY KEY,
		name TEXT NOT NULL,
		email TEXT NOT NULL
		);");
    db.execute("INSERT INTO users VALUES (" ~ text(MARKETS_ID) ~ ", 'markets', 'markets');");
    db.execute("INSERT INTO users VALUES (" ~ text(FUNDER_ID) ~ ", 'funder', 'funder');");
    db.execute("CREATE TABLE predictions (
		id INTEGER PRIMARY KEY,
		b INTEGER, /* b factor for LMSR */
		statement TEXT NOT NULL,
		created TEXT NOT NULL, /* ISO8601 date */
		creator INTEGER, /* id from users */
		closes TEXT NOT NULL, /* ISO8601 date */
		settled TEXT, /* ISO8601 date */
		result TEXT /* yes or no */
		);");
    db.execute("CREATE TABLE orders (
		id INTEGER PRIMARY KEY,
		user INTEGER, /* who traded? */
		prediction INTEGER, /* which prediction? */
		share_count INTEGER, /* amount of shares traded */
		yes_order INTEGER, /* what was bought 1=yes, 2=no */
		date TEXT NOT NULL /* ISO8601 date */
		);");
    db.execute("CREATE TABLE transactions (
		id INTEGER PRIMARY KEY,
		sender INTEGER, /* userid */
		receiver INTEGER, /* userid */
		amount INTEGER,
		prediction INTEGER, /* which prediction? */
		yes_order INTEGER, /* what was bought 0=neither, 1=yes, 2=no */
		date TEXT NOT NULL /* ISO8601 date */
		);");
}

immutable SQL_SELECT_PREDICTION_PREFIX = "SELECT id,b,statement,created,creator,closes,settled,result FROM predictions ";

struct database
{
    Database db;

    @disable this();
    this(string sqlite_path)
    {
        this.db = Database(sqlite_path);
    }

    user getUser(int id)
    {
        auto query = db.prepare("SELECT name, email FROM users WHERE id=?");
        query.bind(1, id);
        foreach (row; query.execute())
        {
            auto name = row.peek!string(0);
            auto email = row.peek!string(1);
            return user(id, name, email);
        }
        throw new Exception("User " ~ text(id) ~ " does not exist.");
    }

    user getUser(string email)
    {
        auto query = db.prepare("SELECT id, name FROM users WHERE email = ?");
        query.bind(1, email);
        foreach (row; query.execute())
        {
            auto id = row.peek!int(0);
            auto name = row.peek!string(1);
            return user(id, name, email);
        }
        writeln("user " ~ email ~ " does not exist yet. Create it.");
        /* user does not exist yet */
        auto name = emailPrefix(email);
        db.execute("BEGIN TRANSACTION;");
        auto q = db.prepare("INSERT INTO users VALUES (NULL, ?, ?);");
        q.bind(1, name);
        q.bind(2, email);
        q.execute();
        auto user = getUser(email);
        transferMoney(FUNDER_ID, user.id, credits(1000), 0, share_type.init);
        db.execute("END TRANSACTION;");
        return user;
    }

    prediction getPrediction(int id)
    {
        auto query = db.prepare(SQL_SELECT_PREDICTION_PREFIX ~ "WHERE id = ?;");
        query.bind(1, id);
        foreach (row; query.execute())
        {
            return parsePredictionQueryRow(row);
        }
        throw new Exception("Prediction " ~ text(id) ~ " does not exist.");
    }

    private user[] users()
    {
        auto query = db.prepare(
            "SELECT id,name,email FROM users WHERE id != ? AND id != ? ORDER BY id;");
        query.bind(1, MARKETS_ID);
        query.bind(2, FUNDER_ID);
        user[] result;
        foreach (row; query.execute())
        {
            auto id = row.peek!int(0);
            auto name = row.peek!string(1);
            auto email = row.peek!string(2);
            result ~= user(id, name, email);
        }
        return result;
    }

    auto getUsersByCash()
    {
        auto us = users();
        bool myComp(user x, user y)
        {
            auto cx = getCash(x.id);
            auto cy = getCash(y.id);
            return cx > cy;
        }

        sort!(myComp)(us);
        return us;
    }

    auto getUsersByClosedPredictions()
    {
        auto us = users();
        bool myComp(user x, user y)
        {
            auto cx = countSettled(x);
            auto cy = countSettled(y);
            return cx > cy;
        }

        sort!(myComp)(us);
        return us;
    }

    int countSettled(user u)
    {
        auto now = Clock.currTime.toUTC.toISOExtString;
        auto query = db.prepare(
            "SELECT COUNT(id) FROM predictions WHERE creator=? AND (settled IS NOT NULL OR closes<?);");
        query.bind(1, u.id);
        query.bind(2, now);
        return query.execute().oneValue!int;
    }

    private auto parsePredictionQuery(ResultRange query)
    {
        prediction[] ret;
        foreach (row; query)
        {
            ret ~= parsePredictionQueryRow(row);
        }
        return ret;
    }

    private auto parsePredictionQueryRow(Row row)
    {
        auto id = row.peek!int(0);
        auto b = row.peek!int(1);
        auto statement = row.peek!string(2);
        auto created = row.peek!string(3);
        auto creator = row.peek!int(4);
        auto closes = row.peek!string(5);
        auto settled = row.peek!string(6);
        auto result = row.peek!string(7);
        auto yes_shares = countPredShares(id, share_type.yes);
        auto no_shares = countPredShares(id, share_type.no);
        return prediction(id, b, statement, creator, yes_shares, no_shares,
            created, closes, settled, result);
    }

    prediction[] activePredictions()
    {
        SysTime now = Clock.currTime.toUTC;
        auto query = db.prepare(
            SQL_SELECT_PREDICTION_PREFIX ~ "WHERE closes > ? AND settled IS NULL ORDER BY closes;");
        query.bind(1, now.toISOExtString());
        return parsePredictionQuery(query.execute());
    }

    prediction[] predictionsToSettle()
    {
        SysTime now = Clock.currTime.toUTC;
        auto query = db.prepare(
            SQL_SELECT_PREDICTION_PREFIX ~ "WHERE closes < ? AND settled IS NULL ORDER BY closes;");
        query.bind(1, now.toISOExtString());
        return parsePredictionQuery(query.execute());
    }

    void createPrediction(int b, string stmt, SysTime closes, user creator)
    {
        SysTime now = Clock.currTime.toUTC;
        db.execute("BEGIN TRANSACTION;");
        enforce(closes > now, "closes date must be in the future");
        auto q = db.prepare("INSERT INTO predictions (id,b,statement,created,creator,closes,settled,result) VALUES (NULL, ?, ?, ?, ?, ?, NULL, NULL);");
        q.bind(1, b);
        q.bind(2, stmt);
        q.bind(3, now.toISOExtString());
        q.bind(4, creator.id);
        q.bind(5, closes.toUTC.toISOExtString);
        q.execute();
        /* get id */
        q = db.prepare("SELECT id FROM predictions WHERE statement=? AND created=?;");
        q.bind(1, stmt);
        q.bind(2, now.toISOExtString());
        auto pid = q.execute().oneValue!int;
        /* prepay the settlement tax */
        auto max_loss = credits(b * log(2));
        transferMoney(creator.id, MARKETS_ID, max_loss, pid, share_type.init);
        db.execute("END TRANSACTION;");
    }

    void buy(int uid, int pid, int amount, share_type t, millicredits price)
    {
        db.execute("BEGIN TRANSACTION;");
        buyWithoutTransaction(uid, pid, amount, t, price);
        db.execute("END TRANSACTION;");
    }

    private void buyWithoutTransaction(int uid, int pid, int amount,
        share_type t, millicredits price)
    {
        enforce(getCash(uid) >= price, "not enough cash");
        transferShares(uid, pid, amount, t);
        transferMoney(uid, MARKETS_ID, price, pid, t);
    }

    private void transferShares(int uid, int pid, int amount, share_type t)
    {
        auto now = Clock.currTime.toUTC.toISOExtString;
        auto q = db.prepare("INSERT INTO orders VALUES (NULL, ?, ?, ?, ?, ?);");
        q.bind(1, uid);
        q.bind(2, pid);
        q.bind(3, amount);
        q.bind(4, t);
        q.bind(5, now);
        q.execute();
    }

    private void transferMoney(int sender, int receiver, millicredits amount,
        int predid, share_type t)
    {
        auto now = Clock.currTime.toUTC.toISOExtString;
        auto q = db.prepare("INSERT INTO transactions VALUES (NULL, ?, ?, ?, ?, ?, ?);");
        q.bind(1, sender);
        q.bind(2, receiver);
        q.bind(3, amount.amount);
        q.bind(4, predid);
        q.bind(5, t);
        q.bind(6, now);
        q.execute();
    }

    millicredits getCash(int userid)
    {
        auto query = db.prepare("SELECT SUM(amount) FROM transactions WHERE sender = ?;");
        query.bind(1, userid);
        auto spent = query.execute().oneValue!long;
        query = db.prepare("SELECT SUM(amount) FROM transactions WHERE receiver = ?;");
        query.bind(1, userid);
        auto received = query.execute().oneValue!long;
        return millicredits(received - spent);
    }

    auto usersActivePredictions(int userid)
    {
        SysTime now = Clock.currTime.toUTC;
        auto query = db.prepare(
            SQL_SELECT_PREDICTION_PREFIX ~ "WHERE creator == ? AND closes > ? ORDER BY closes;");
        query.bind(1, userid);
        query.bind(2, now.toISOExtString());
        return parsePredictionQuery(query.execute());
    }

    auto usersClosedPredictions(int userid)
    {
        SysTime now = Clock.currTime.toUTC;
        auto query = db.prepare(
            SQL_SELECT_PREDICTION_PREFIX ~ "WHERE creator == ? AND closes < ? ORDER BY closes;");
        query.bind(1, userid);
        query.bind(2, now.toISOExtString());
        return parsePredictionQuery(query.execute());
    }

    void setUserName(int userid, string name)
    {
        auto query = db.prepare("UPDATE users SET name=? WHERE id=?;");
        query.bind(1, name);
        query.bind(2, userid);
        query.execute();
    }

    auto getLastOrders()
    {
        order[] ret;
        auto query = db.prepare(
            "SELECT prediction, share_count, yes_order, date FROM orders ORDER BY date DESC LIMIT 10;");
        foreach (row; query.execute())
        {
            auto predid = row.peek!int(0);
            auto share_count = row.peek!int(1);
            auto yes_order = row.peek!int(2);
            auto date = row.peek!string(3);
            ret ~= order(predid, share_count, fromInt(yes_order), date);
        }
        return ret;
    }

    auto getUsersPredStats(int userid, int predid)
    {
        predStats ret;
        {
            auto query = db.prepare(
                "SELECT SUM(share_count) FROM orders WHERE prediction = ? AND user = ? AND yes_order = ?;");
            query.bind(1, predid);
            query.bind(2, userid);
            query.bind(3, 1);
            ret.yes_shares = query.execute().oneValue!int;
            query.reset();
            query.bind(1, predid);
            query.bind(2, userid);
            query.bind(3, 2);
            ret.no_shares = query.execute().oneValue!int;
        }
        ret.yes_price = getInvestment(userid, predid, share_type.yes);
        ret.no_price = getInvestment(userid, predid, share_type.no);
        return ret;
    }

    private millicredits getInvestment(int userid, int predid, share_type t)
    {
        auto query = db.prepare(
            "SELECT SUM(amount) FROM transactions WHERE prediction=? AND sender=? AND yes_order=?;");
        query.bind(1, predid);
        query.bind(2, userid);
        query.bind(3, t);
        return millicredits(query.execute().oneValue!long);
    }

    void settle(int pid, bool result)
    {
        auto now = Clock.currTime.toUTC.toISOExtString;
        db.execute("BEGIN TRANSACTION;");
        auto pred = getPrediction(pid); // within TRANSACTION
        /* mark prediction as settled now */
        {
            auto query = db.prepare("UPDATE predictions SET settled=?, result=? WHERE id=?;");
            query.bind(1, now);
            query.bind(2, result ? "yes" : "no");
            query.bind(3, pred.id);
            query.execute();
        }
        /* The market maker/creator has to balance the shares,
           which means to balance shares such that yes==no. */
        {
            auto amount = abs(pred.yes_shares - pred.no_shares);
            if (amount > 0)
            {
                auto t = pred.yes_shares < pred.no_shares ? share_type.yes : share_type.no;
                auto price = pred.cost(amount, t);
                transferShares(pred.creator, pred.id, amount, t);
                /* due to prepay, creator gets some money back */
                auto max_loss = credits(pred.b * log(2));
                auto payback = max_loss - price;
                if (payback != credits(0))
                    transferMoney(MARKETS_ID, pred.creator, payback, pred.id, share_type.balance);
            }
        }
        /* payout */
        {
            auto query = db.prepare(
                "SELECT user, SUM(share_count) FROM orders WHERE prediction=? AND yes_order=?;");
            query.bind(1, pred.id);
            query.bind(2, result ? 1 : 2);
            int[int] shares;
            foreach (row; query.execute())
            {
                auto userid = row.peek!int(0);
                auto amount = row.peek!int(1);
                writeln("order " ~ text(amount) ~ " shares for " ~ text(userid));
                transferMoney(MARKETS_ID, userid, credits(amount), pred.id, share_type.balance);
            }
        }
        db.execute("END TRANSACTION;");
    }

    chance_change[] getPredChanges(prediction pred)
    {
        chance_change[] changes;
        changes ~= chance_change(pred.created, 0.5, 0, share_type.balance);
        auto query = db.prepare(
            "SELECT share_count, yes_order, date FROM orders WHERE prediction=? ORDER BY date;");
        query.bind(1, pred.id);
        int yes_shares, no_shares;
        foreach (row; query.execute())
        {
            auto amount = row.peek!int(0);
            auto y = row.peek!int(1);
            share_type type;
            auto date = row.peek!string(2);
            if (y == 1)
            {
                type = share_type.yes;
                yes_shares += amount;
            }
            else
            {
                assert(y == 2);
                type = share_type.no;
                no_shares += amount;
            }
            auto chance = LMSR_chance(pred.b, yes_shares, no_shares);
            changes ~= chance_change(date, chance, amount, type);
        }
        if (pred.settled != "")
        {
            /* last element is the balancing of the creator during settlement */
            changes.length -= 1;
        }
        return changes;
    }

    private int countPredShares(prediction pred, share_type t)
    {
        return countPredShares(pred.id, t);
    }

    private int countPredShares(int predid, share_type t)
    {
        auto query = db.prepare(
            "SELECT SUM(share_count), yes_order FROM orders WHERE prediction=? AND yes_order=? ORDER BY date;");
        query.bind(1, predid);
        query.bind(2, t);
        return query.execute().oneValue!int();
    }

    int countPredShares(prediction pred, user u, share_type t)
    {
        auto query = db.prepare(
            "SELECT SUM(share_count) FROM orders WHERE prediction=? AND user=? AND yes_order=?;");
        query.bind(1, pred.id);
        query.bind(2, u.id);
        query.bind(3, t);
        return query.execute().oneValue!int;
    }
}

struct predStats
{
    int yes_shares, no_shares;
    millicredits yes_price, no_price;
}

struct order
{
    int predid, share_count;
    share_type type;
    string date;
}

struct chance_change
{
    string date;
    real chance;
    int shares;
    share_type type;
}

struct prediction
{
    int id, b;
    string statement;
    int creator, yes_shares, no_shares;
    string created, closes, settled, result;

    /* chance that statement happens according to current market */
    real chance() const pure @safe nothrow
    {
        return LMSR_chance(b, yes_shares, no_shares);
    }

    /* cost of buying a certain amount of shares */
    millicredits cost(int amount, share_type t) const
    {
        if (t == share_type.yes)
        {
            auto c = LMSR_cost(b, yes_shares, no_shares, amount);
            return millicredits(to!long(1000.0 * c));
        }
        else
        {
            assert(t == share_type.no);
            auto c = LMSR_cost(b, no_shares, yes_shares, amount);
            return millicredits(to!long(1000.0 * c));
        }
    }

    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink("prediction(");
        sink(statement);
        sink(" ");
        sink.formattedWrite("%.2f%%", chance * 100);
        sink(")");
    }
}

string emailPrefix(const(string) email)
{
    auto r = findSplitBefore(email, "@");
    return r[0];
}

struct user
{
    int id;
    string name, email;
    @disable this();
    this(int id, string name, string email)
    {
        this.id = id;
        this.name = name;
        this.email = email;
    }

    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink("user(");
        sink(email);
        sink(")");
    }
}

database getDatabase()
{
    auto path = "prema.sqlite3";
    bool init = !exists(path);
    auto db = database(path);
    if (init)
    {
        init_empty_db(db.db);
    }
    return db;
}

database getMemoryDatabase()
{
    auto db = database(":memory:");
    init_empty_db(db.db);
    return db;
}

real LMSR_C(real b, real yes, real no) pure nothrow @safe
{
    return b * log(exp(yes / b) + exp(no / b));
}

real LMSR_cost(real b, real yes, real no, real amount) pure nothrow @safe
{
    return LMSR_C(b, yes + amount, no) - LMSR_C(b, yes, no);
}

unittest
{
    void assert_roughly(real a, real b)
    {
        immutable real epsilon = 0.01;
        assert(a + epsilon > b && b > a - epsilon, text(a) ~ " !~ " ~ text(b));
    }

    assert_roughly(LMSR_cost(100, 0, 0, 1), 0.50);
    assert_roughly(LMSR_cost(100, 0, 0, 10), 5.12);
    assert_roughly(LMSR_cost(100, 0, 0, 100), 62.01);
    assert_roughly(LMSR_cost(100, 0, 0, 1000), 930.69);
    assert_roughly(LMSR_cost(100, 0, 0, 10000), 9930.69);
    assert_roughly(LMSR_cost(100, 50, 10, -10), -5.87);
    assert_roughly(LMSR_cost(100, 20, 15, 20), 10.75);
}

real LMSR_chance(real b, real yes, real no) pure nothrow @safe
{
    const y = LMSR_cost(b, yes, no, 1);
    const n = LMSR_cost(b, no, yes, 1);
    return y / (y + n);
}

unittest
{
    void assert_roughly(real a, real b)
    {
        immutable real epsilon = 0.01;
        assert(a + epsilon > b && b > a - epsilon, text(a) ~ " !~ " ~ text(b));
    }

    assert_roughly(LMSR_chance(10, 0, 0), 0.5);
    assert_roughly(LMSR_chance(100, 0, 0), 0.5);
    assert_roughly(LMSR_chance(1000, 0, 0), 0.5);
    assert_roughly(LMSR_chance(10000, 0, 0), 0.5);
    assert_roughly(LMSR_chance(100, 50, 10), 0.6);
    assert_roughly(LMSR_chance(100, 10, 50), 0.4);
    assert_roughly(LMSR_chance(100, 20, 15), 0.5122);
    assert_roughly(LMSR_chance(100, 15, 20), 0.4878);
    assert_roughly(LMSR_chance(100, 1, 0), 0.5025);
    assert_roughly(LMSR_chance(100, 10, 0), 0.5244);
    assert_roughly(LMSR_chance(100, 100, 0), 0.7306);
    assert_roughly(LMSR_chance(100, 1000, 0), 1.0000);
}

unittest
{
    auto db = getMemoryDatabase();
    auto user = db.getUser(1);
    SysTime now = Clock.currTime.toUTC;
    auto end1 = now + dur!"hours"(7);
    db.createPrediction(100, "This app will actually be used.", end1, user);
    auto end2 = now + dur!"hours"(8);
    db.createPrediction(100, "Michelle Obama becomes president.", end2, user);
    foreach (p; db.activePredictions)
    {
        assert(p.statement);
        assert(p.chance >= 0.0);
        assert(p.chance <= 1.0);
        assert(SysTime.fromISOExtString(p.created) != now);
        assert(SysTime.fromISOExtString(p.closes) != now);
        if (p.settled != "")
            assert(SysTime.fromISOExtString(p.settled) < now);
    }
}

unittest
{
    auto db = getMemoryDatabase();
    auto user = db.getUser("foo@bar.de");
    auto stmt = "This app will be actually used.";
    SysTime now = Clock.currTime.toUTC;
    auto end = now + dur!"hours"(7);
    db.createPrediction(100, stmt, end, user);
    auto admin = db.getUser(user.id);
    auto pred = db.getPrediction(1);
    assert(pred.statement == stmt);
    void assert_roughly(real a, real b)
    {
        immutable real epsilon = 0.001;
        assert(a + epsilon > b && b > a - epsilon, text(a) ~ " !~ " ~ text(b));
    }

    assert(pred.yes_shares == 0, text(pred.yes_shares));
    assert(pred.no_shares == 0, text(pred.no_shares));
    assert_roughly(pred.chance, 0.5);
    auto price = pred.cost(10, share_type.no);
    assert(pred.cost(10, share_type.yes) == price);
    db.buy(admin.id, pred.id, 10, share_type.no, price);

    auto pred2 = db.getPrediction(1);
    assert(pred2.cost(10, share_type.no) > price, text(pred2.cost(10,
        share_type.no)) ~ " !> " ~ text(price));
    /* check for database state */
    auto admin2 = db.getUser(user.id);
    auto pred22 = db.getPrediction(pred2.id);
    assert(pred2.yes_shares == 0, text(pred2.yes_shares));
    assert(pred2.no_shares == 10, text(pred2.no_shares));
    auto price2 = pred2.cost(10, share_type.no);
}
