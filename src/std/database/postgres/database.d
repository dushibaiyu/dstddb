module std.database.postgres.database;
pragma(lib, "pq");
pragma(lib, "pgtypes");

import std.string;
import core.stdc.stdlib;

import std.database.postgres.bindings;
import std.database.common;
import std.database.exception;
import std.database.source;
import std.database.allocator;
import std.container.array;
import std.experimental.logger;
import std.database.front;

import std.stdio;
import std.typecons;
import std.datetime;
import std.conv;

struct DefaultPolicy {
    alias Allocator = MyMallocator;
    static const bool nonblocking = false;
}

alias Database(T) = BasicDatabase!(Driver!T, T);

auto createDatabase()(string defaultURI = "") {
    return Database!DefaultPolicy(defaultURI);
}

auto createDatabase(T)(string defaultURI = "") {
    return Database!T(defaultURI);
}

/*
   auto createAsyncDatabase()(string defaultURI="") {
   return Database!DefaultAsyncPolicy(defaultURI);  
   }
 */

void error(string file = __FILE__, size_t line = __LINE__)(PGconn* con, string msg) {
    import std.conv;

    auto s = msg ~ to!string(PQerrorMessage(con));
    throw new DatabaseException(s,file,line);
}

void error(string file = __FILE__, size_t line = __LINE__)(PGconn* con, string msg, int result) {
    import std.conv;

    auto s = "error:" ~ msg ~ ": " ~ to!string(result) ~ ": " ~ to!string(PQerrorMessage(con));
	throw new DatabaseException(s,file,line);
}

int check(string file = __FILE__, size_t line = __LINE__)(PGconn* con, string msg, int result) {
    info(msg, ": ", result);
    if (result != 1)
        error!(file,line)(con, msg, result);
    return result;
}

int checkForZero(string file = __FILE__, size_t line = __LINE__)(PGconn* con, string msg, int result) {
    info(msg, ": ", result);
    if (result != 0)
		error!(file,line)(con, msg, result);
    return result;
}

struct Driver(Policy) {
    alias Allocator = Policy.Allocator;
    alias Cell = BasicCell!(Driver, Policy);

    struct Database {
        static const auto queryVariableType = QueryVariableType.Dollar;

        static const FeatureArray features = [Feature.InputBinding, Feature.DateBinding,
            //Feature.ConnectionPool,
            ];

        Allocator allocator;

        this(string defaultURI_) {
            allocator = Allocator();
        }

        ~this() {
        }
    }

    struct Connection {
        Database* db;
        Source source;
        PGconn* con;

        this(Database* db_, Source source_) {
            db = db_;
            source = source_;

            string conninfo;
            if(source.host.length > 0)
            {
                conninfo ~= "host=" ~ source.host;
                if(source.port > 0) conninfo ~= " port=" ~ to!string(source.port);
            }
            else
            {
                conninfo ~= "host=" ~ source.server;
            }
            conninfo ~= " dbname=" ~ source.database;
            if(source.username.length > 0) conninfo ~= " user=" ~ source.username;
            if(source.password.length > 0) conninfo ~= " password=" ~ source.password;
            trace("link string is : ", conninfo);
            con = PQconnectdb(toStringz(conninfo));
            if (PQstatus(con) != CONNECTION_OK)
                error(con, "login error");
        }

        ~this() {
            PQfinish(con);
        }

        int socket() {
            return PQsocket(con);
        }

        void* handle() {
            return con;
        }
    }

    struct Statement {
        Connection* connection;
        string sql;
        Allocator* allocator;
        PGconn* con;
        string name;
        PGresult* prepareRes;
        PGresult* res;

     /*   Array!(char*) bindValue;
        Array!(Oid) bindType;
        Array!(int) bindLength;
        Array!(int) bindFormat;*/

        this(Connection* connection_, string sql_) {
            connection = connection_;
            sql = sql_;
            allocator = &connection.db.allocator;
            con = connection.con;
            //prepare();
        }

        ~this() {
/*            for (int i = 0; i != bindValue.length; ++i) {
                auto ptr = bindValue[i];
                auto length = bindLength[i];
                allocator.deallocate(ptr[0 .. length]);
            }*/
        }

        void bind(int n, int value) {
        }

        void bind(int n, const char[] value) {
        }

        void query() {
            import std.conv;

            trace("query sql: ", sql);

            static if (Policy.nonblocking) {

                checkForZero(con, "PQsetnonblocking", PQsetnonblocking(con, 1));

                check(con, "PQsendQueryPrepared", PQsendQuery(con,toStringz(sql)));

                do {
                    Policy.Handler handler;
                    handler.addSocket(posixSocket());
                    /*
                       auto s = PQconnectPoll(con);
                       if (s == PGRES_POLLING_OK) {
                       log("READY");
                       break;
                       }
                     */
                    log("waiting: ");
                    checkForZero(con, "PQflush", PQflush(con));
                    handler.wait();
                    check(con, "PQconsumeInput", PQconsumeInput(con));

                    PGnotify* notify;
                    while ((notify = PQnotifies(con)) != null) {
                        info("notify: ", to!string(notify.relname));
                        PQfreemem(notify);
                    }

                }
                while (PQisBusy(con) == 1);

                res = PQgetResult(con);

            }
            else {
                res = PQexec(con,toStringz(sql));
            }
        }

        void query(X...)(X args) {
            info("query sql: ", sql);

            // todo: stack allocation

    /*        bindValue.clear();
            bindType.clear();
            bindLength.clear();
            bindFormat.clear();

            foreach (ref arg; args)
                bind(arg);
    
            auto n = bindValue.length;

            /*
               types must be set in prepared
               res = PQexecPrepared(
               con,
               toStringz(name),
               cast(int) n,
               n ? cast(const char **) &bindValue[0] : null,
               n ? cast(int*) &bindLength[0] : null,
               n ? cast(int*) &bindFormat[0] : null,
               0);
             */

       /*     int resultForamt = 0;

            res = PQexecParams(con, toStringz(sql), cast(int) n,
                n ? cast(Oid*)&bindType[0] : null,
                n ? cast(const char**)&bindValue[0] : null,
                n ? cast(int*)&bindLength[0] : null,
                n ? cast(int*)&bindFormat[0] : null, resultForamt);
        */
        }

        bool hasRows() {
            return rowCout() > 0;
        }
        
        int rowCout()
        {
            int r = 0;
            if(res !is null) r = PQntuples(res);
            return r;
        }
/*
        int binds() {
            return cast(int) bindValue.length;
        } // fix

        void bind(string v) {
            import core.stdc.string : strncpy;

            void[] s = allocator.allocate(v.length + 1);
            char* p = cast(char*) s.ptr;
            strncpy(p, v.ptr, v.length);
            p[v.length] = 0;
            bindValue ~= p;
            bindType ~= 0;
            bindLength ~= 0;
            bindFormat ~= 0;
        }

        void bind(int v) {
            import std.bitmanip;

            void[] s = allocator.allocate(int.sizeof);
            *cast(int*) s.ptr = peek!(int, Endian.bigEndian)(cast(ubyte[])(&v)[0 .. int.sizeof]);
            bindValue ~= cast(char*) s.ptr;
            bindType ~= INT4OID;
            bindLength ~= cast(int) s.length;
            bindFormat ~= 1;
        }

        void bind(Date v) {
            /* utility functions take 8 byte values but DATEOID is a 4 byte value */
       /*     import std.bitmanip;

            int[3] mdy;
            mdy[0] = v.month;
            mdy[1] = v.day;
            mdy[2] = v.year;
            long d;
            PGTYPESdate_mdyjul(&mdy[0], &d);
            void[] s = allocator.allocate(4);
            *cast(int*) s.ptr = peek!(int, Endian.bigEndian)(cast(ubyte[])(&d)[0 .. 4]);
            bindValue ~= cast(char*) s.ptr;
            bindType ~= DATEOID;
            bindLength ~= cast(int) s.length;
            bindFormat ~= 1;
        }
*/
        void prepare() {
            const Oid* paramTypes;
            prepareRes = PQprepare(con, toStringz(name), toStringz(sql), 0, paramTypes);
        }

        auto error(string msg) {
            import std.conv;

            string s;
            s ~= msg ~ ", " ~ to!string(PQerrorMessage(con));
            return new DatabaseException(s);
        }

        void reset() {
        }

        private auto posixSocket() {
            int s = PQsocket(con);
            if (s == -1)
                throw new DatabaseException("can't get socket");
            return s;
        }

    }

    struct Describe {
        int dbType;
        int fmt;
        string name;
    }
	// use std.database.front.ValueType not std.traits.ValueType
    alias ValueType = std.database.front.ValueType;
    struct Bind {
        ValueType type;
        int idx;
        //int fmt;
        //int len;
        //int isNull; 
    }

    struct Result {
        Statement* stmt;
        PGconn* con;
        PGresult* res;
        int columns;
        Array!Describe describe;
        ExecStatusType status;
        int row;
        int rows;
        bool hasResult_;
        bool fristFecth = true;

        // artifical bind array (for now)
        Array!Bind bind;

        this(Statement* stmt_, int rowArraySize_) {
            stmt = stmt_;
            con = stmt.con;
            res = stmt.res;
            trace("build a rulest!");
            setup();

            build_describe();
            build_bind();
            trace("end a rulest!");
        }

        ~this() {
            trace("~this() { rulest!");
            if (res)
                close();
        }

        bool setup() {
           // trace("setup");
            if (!res) {
                throw error("no result: result is null");
            }
            status = PQresultStatus(res);
            rows = PQntuples(res);
           // trace("status is ", status);
            // not handling PGRESS_SINGLE_TUPLE yet
            if (status == PGRES_COMMAND_OK) {
                close();
                return false;
            }
            else if (status == PGRES_EMPTY_QUERY) {
                close();
                return false;
            }
            else if (status == PGRES_TUPLES_OK) {
                return true;
            }
            else 
                throw error(res, status);
        }

        void build_describe() {
            import std.conv;
            trace("build_describe!");
            // called after next()
            columns = PQnfields(res);
            for (int col = 0; col != columns; col++) {
                describe ~= Describe();
                auto d = &describe.back();
                d.dbType = cast(int) PQftype(res, col);
                d.fmt = PQfformat(res, col);
                d.name = to!string(PQfname(res, col));
            }
        }

        void build_bind() {
            trace("build_bind!");
            // artificial bind setup
            bind.reserve(columns);
            for (int i = 0; i < columns; ++i) {
                auto d = &describe[i];
                bind ~= Bind();
                auto b = &bind.back();
                b.type = ValueType.String;
                b.idx = i;
                switch (d.dbType) {
                case CHAROID:
                    b.type = ValueType.Char;
                    break;
                case TEXTOID:
                case NAMEOID:
                case VARCHAROID:
                    b.type = ValueType.String;
                    break;
                case BOOLOID:
                case INT4OID:
                    b.type = ValueType.Int;
                    break;
                case INT2OID:
                    b.type = ValueType.Short;
                    break;
                case INT8OID:
                    b.type = ValueType.Long;
                    break;
                case FLOAT4OID:
                    b.type = ValueType.Float;
                    break;
                case FLOAT8OID:
                    b.type = ValueType.Double;
                    break;
                case DATEOID:
                    b.type = ValueType.Date;
                    break;
                case TIMEOID:
                    b.type = ValueType.Time;
                    break;
                case TIMESTAMPOID:
                    b.type = ValueType.DateTime;
                    break;
                case BYTEAOID:
                    b.type = ValueType.Raw;
                    break;
                default:
                    b.type = ValueType.UNKnown;
                    break;
                   // throw new DatabaseException("unsupported type");
                }
            }
        }

        int fetch() {
            int r = 0;
            if(fristFecth)
                r = rows > 0 ? 1 : 0;
            else 
            {
                ++row;
                r = row != rows ? 1 : 0;
            }
            fristFecth = false;
            return r;
        }

        bool singleRownext() {
            if (res)
                PQclear(res);
            res = PQgetResult(con);
            if (!res)
                return false;
            status = PQresultStatus(res);

            if (status == PGRES_COMMAND_OK) {
                close();
                return false;
            }
            else if (status == PGRES_SINGLE_TUPLE)
                return true;
            else if (status == PGRES_TUPLES_OK) {
                close();
                return false;
            }
            else
                throw error(status);
        }

        void close() {
            if (!res)
                throw error("couldn't close result: result was not open");
            res = PQgetResult(con);
            if (res)
                throw error("couldn't close result: was not finished");
            res = null;
        }

		auto error(string file = __FILE__, size_t line = __LINE__)(string msg) {
            return new DatabaseException(msg,file,line);
        }

		auto error(string file = __FILE__, size_t line = __LINE__)(ExecStatusType status) {
            import std.conv;

            string s = "result error: " ~ to!string(PQresStatus(status));
			return new DatabaseException(s,file,line);
        }

		auto error(string file = __FILE__, size_t line = __LINE__)(PGresult* res, ExecStatusType status) {
            import std.conv;

            const char* msg = PQresultErrorMessage(res);
            string s = "error: " ~ to!string(PQresStatus(status)) ~ ", message:" ~ to!string(msg);
			return new DatabaseException(s,file,line);
        }

        /*
           char[] get(X:char[])(Bind *b) {
           auto ptr = cast(char*) b.data.ptr;
           return ptr[0..b.length];
           }
         */

        auto name(size_t idx) {
            return describe[idx].name;
        }

        ubyte[] rawData(Cell* cell) {
            auto ptr = cast(ubyte*) data(cell.bind.idx);
            return ptr[0 .. len(cell.bind.idx)];
        }

        Variant getValue(Cell* cell) {
            import std.conv;

            Variant value;
            if (isNull(cell))
                return value;

            void* dt = data(cell.bind.idx);
            int leng = len(cell.bind.idx);
            immutable char* ptr = cast(immutable char*) dt;
            string str = cast(string) ptr[0 .. leng];
            switch (type(cell.bind.idx)) {
            case VARCHAROID: 
            case TEXTOID:
            case NAMEOID:{
                    value = str;
                }
                break;
            case INT2OID: {
                    value = parse!short(str);
                }
                break;
            case INT4OID: {
                    value = parse!int(str);
                }
                break;
            case INT8OID: {
                   value = parse!long(str);
                }
                break;
            case FLOAT4OID: {
                   value = parse!float(str);
                }
                break;
            case FLOAT8OID: {
                    value = parse!double(str);
                }
                break;
            case DATEOID: {
                    import std.format: formattedRead;
                    string input = str;
                    int year, month, day;
                    formattedRead(input, "%s-%s-%s", &year, &month, &day);
                    value =  Date(year, month, day);
                }
                break;
            case TIMESTAMPOID: {
                    import std.string;
                    
                    value = DateTime.fromISOExtString(str.translate([' ' : 'T']).split('.').front());
                }
                break;
            case TIMEOID: {
                    value = parseTimeoid(str);
                }
                break;
            case BYTEAOID: {
                    value = byteaToUbytes(str);
                }
                break;
            case CHAROID: {
                    value = cast(char)(leng > 0 ? str[0] : 0x00);
                }
                break;
            case BOOLOID: {

                    if (str == "true" || str == "t" || str == "1")
                            value = 1;
                    else if (str == "false" || str == "f" || str == "0")
                            value = 0;
                    else 
                        value = parse!int(str);
                }
                break;
            default:
                break;
            }
            trace("value is : ",value );
            return value;
        }

        bool isNull(Cell* cell) {
            return PQgetisnull(res, row, cell.bind.idx) != 0;
        }

        void checkType(int a, int b) {
            if (a != b)
                throw new DatabaseException("type mismatch");
        }

        void* data(int col) {
            return PQgetvalue(res, row, col);
        }

        bool isNull(int col) {
            return PQgetisnull(res, row, col) != 0;
        }

        auto type(int col) {
            return describe[col].dbType;
        }

        int fmt(int col) {
            return describe[col].fmt;
        }

        int len(int col) {
            return PQgetlength(res, row, col);
        }

    }
}

// the under is from ddbc:
import core.vararg;
import std.exception;
import std.meta;
import std.range.primitives;
import std.traits;
import std.format;

Time parseTimeoid(const string timeoid) {
    import std.format;

    string input = timeoid.dup;
    int hour, min, sec;
    formattedRead(input, "%s:%s:%s", &hour, &min, &sec);
    return Time(hour, min, sec);
}

ubyte[] byteaToUbytes(string s) {
    if (s is null)
        return null;
    ubyte[] res;
    bool lastBackSlash = 0;
    foreach (ch; s) {
        if (ch == '\\') {
            if (lastBackSlash) {
                res ~= '\\';
                lastBackSlash = false;
            }
            else {
                lastBackSlash = true;
            }
        }
        else {
            if (lastBackSlash) {
                if (ch == '0') {
                    res ~= 0;
                }
                else if (ch == 'r') {
                    res ~= '\r';
                }
                else if (ch == 'n') {
                    res ~= '\n';
                }
                else if (ch == 't') {
                    res ~= '\t';
                }
                else {
                }
            }
            else {
                res ~= cast(byte) ch;
            }
            lastBackSlash = false;
        }
    }
    return res;
}
