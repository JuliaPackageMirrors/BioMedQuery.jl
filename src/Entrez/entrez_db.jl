module DB

using ...DBUtils
using ..Entrez
using SQLite
using MySQL
using DataStreams, DataFrames
using NullableArrays

export init_pubmed_db_mysql,
       init_pubmed_db_sqlite,
       get_value,
       all_pmids,
       get_article_mesh,
       db_insert!


get_value{T}(val::Nullable{T}) = get(val)
get_value(val)= val
get_value{T}(val_array::Array{T}) = val_array
get_value{T}(val_array::NullableArray{T, 1}) = val_array.values

function init_pubmed_db_mysql(config)

    println("Initializing MySQL Database")

    #intput dictionary must have the following keys
    if haskey(config, :host) && haskey(config, :dbname) &&
       haskey(config, :username) && haskey(config, :pswd) &&
       haskey(config, :overwrite)

       mysql_code=nothing
       try
           filename = Pkg.dir() * "/BioMedQuery/src/Entrez/create_pubmed_db.sql"
           println(filename)
           f = open(filename, "r")
           mysql_code = readall(f)
           close(f)
       catch
           error("Could not read create_entrez_db.sql")
       end

       db = DBUtils.init_mysql_database(host = config[:host], dbname =config[:dbname],
       username = config[:username], pswd= config[:pswd],
       overwrite = config[:overwrite], mysql_code = mysql_code)

       return db
   end
end

function init_pubmed_db_sqlite(config)
    println("Initializing SQLite Database")
    if haskey(config, :db_path) && haskey(config, :overwrite)
        db = init_pubmed_db_sqlite(config[:db_path], config[:overwrite])
        return db
    else
        println("Error with following configuration:")
        println(config)
        println("Must contain: db_path")
        error("Improper configuration for entrez_sqlite:init_database")
    end
end

# Creates a database with all necessary tables to store
# Entrez related searches. All tables are empty at this point
# If a database existis at the given path - an error is ruturned an the user
# is asked whether he intended to clean the existing file
function init_pubmed_db_sqlite(path::ASCIIString, overwrite=false)


    if isfile(path)
        if overwrite
            rm(path)
        else
            println("Database found. Returning existing database.")
            return SQLite.DB(path)
        end
    end

    #Create database file
    db = SQLite.DB(path)

    #Create tables to store
    SQLite.query(db, "CREATE TABLE
    article(pmid INTEGER NOT NULL PRIMARY KEY,
    title TEXT,
    pubYear INTEGER)")


    SQLite.query(db, "CREATE TABLE
    author(id INTEGER PRIMARY KEY AUTOINCREMENT,
    forename TEXT,
    lastname TEXT NOT NULL,
    CONSTRAINT unq UNIQUE(forename,  lastname) )")

    SQLite.query(db, "CREATE TABLE
    author2article(aid INTEGER, pmid INTEGER,
    FOREIGN KEY(aid) REFERENCES author(id),
    FOREIGN KEY(pmid) REFERENCES article(pmid),
    PRIMARY KEY(aid, pmid) )")

    #--------------------------
    # MeshHeading Tables
    #--------------------------

    #Descriptor
    #The id corresponds to the DUI of mesh library
    #Adding a "D" at the beginning of the id, allows for
    #lookup in the mesh browerser
    # https://www.nlm.nih.gov/mesh/MBrowser.html
    SQLite.query(db, "CREATE TABLE
    mesh_descriptor(id INTEGER NOT NULL PRIMARY KEY ,
                    name TEXT UNIQUE )")

    #Qualifier
    SQLite.query(db, "CREATE TABLE
    mesh_qualifier(id INTEGER NOT NULL PRIMARY KEY ,
                   name TEXT UNIQUE )")

    #Heading
    SQLite.query(db, "CREATE TABLE
    mesh_heading(id INTEGER PRIMARY KEY AUTOINCREMENT,
                 pmid INTEGER, did INTEGER, qid INTEGER,
                 dmjr TEXT, qmjr TEXT,
                 FOREIGN KEY(pmid) REFERENCES article(pmid),
                 FOREIGN KEY(did) REFERENCES mesh_descriptor(id),
                 FOREIGN KEY(qid) REFERENCES mesh_qualifier(id),
                 CONSTRAINT unq UNIQUE(pmid, did, qid) )")

    return db

end

"""
    all_pmids(db)
Return all PMIDs stored in the *article* table of the input database
"""
function all_pmids(db)
    query = db_query(db, "SELECT pmid FROM article;")
    return get_value(query[1])
end

"""
    all_mesh(db)
Return all PMIDs stored in the *article* table of the input database
"""
function all_mesh(db)
    query = db_query(db, "SELECT name FROM mesh_descriptor;")
    return get_value(query[1])
end


"""
    get_article_mesh(db, pmid)
Get the all mesh-descriptors associated with a give article
"""
function get_article_mesh(db, pmid::Integer)

    query_string = "SELECT md.name
                      FROM mesh_heading as mh,
                           mesh_descriptor as md
                     WHERE mh.did = md.id
                      AND mh.pmid = $pmid"
    query  = db_query(db, query_string)
    #return data array
    return get_value(query.columns[1])

end

function db_insert!(db, article::PubMedArticle, verbose=false)
    #------- PMID - TITLE - YEAR
    isnull(article.pmid) && error("NULL PMID")

    # Save article data
    insert_row!(db, "article", Dict(:pmid =>article.pmid.value,
                                    :title=>get(article.title, ""),
                                    :pubYear=>get(article.year, 0)), verbose)

    #------- AUTHORS
    for au in article.authors
        if isnull(au[:LastName])
           println("Skipping author, null field: ", au)
           continue
        end

        author_id = insert_row!(db, "author",
        Dict(:id => nothing,
             :forename => get(au[:ForeName], "Unknown"),
             :lastname => get(au[:LastName], nothing)), verbose)

        if author_id < 0
            sel = db_select(db, ["id"], "author",
            Dict(:forename => get(au[:ForeName], "Unknown"),
                 :lastname => au[:LastName].value))
            if length(sel[1]) > 0
                author_id = get_value(sel[1][1])
                if verbose
                    println("Author already in db: ", au)
                end
                insert_row!(db, "author2article",
                Dict(:aid =>author_id, :pmid => article.pmid.value), verbose)
            else
                error("Can't save nor find Author: ", au)
            end
        end
    end
end

function db_insert!(db, pmid::Int64, mesh_heading_list::MeshHeadingList, verbose=false)
    for heading in mesh_heading_list

        did_int = heading.descriptor_id.value
        descriptor_name = heading.descriptor_name.value
        dmjr = get(heading.descriptor_mjr, nothing)


        #Save Descriptor
        insert_row!(db, "mesh_descriptor",
        Dict(:id=>did_int,
             :name=>descriptor_name),
             verbose)

        if isempty(heading.qualifier_id)
            #Save Headings
            insert_row!(db, "mesh_heading",
            Dict(:id=>nothing,
                 :pmid=> pmid,
                 :did=>did_int,
                 :qid=>nothing,
                 :dmjr=>nothing, :qmjr=>nothing), verbose )
        else

            for i=1:length(heading.qualifier_id)
                qid_int = get(heading.qualifier_id[i], -1)
                qualifier_name = get(heading.qualifier_name[i], nothing)
                qmjr = get(heading.qualifier_mjr[i], nothing)

                #Save Qualifiers`
                insert_row!(db, "mesh_qualifier",
                Dict(:id=>qid_int,
                     :name=>qualifier_name),
                     verbose )

                #Save Headings
                insert_row!(db, "mesh_heading",
                Dict(:id=>nothing,
                     :pmid=> pmid,
                     :did=>did_int,
                     :qid=>qid_int,
                     :dmjr=>dmjr, :qmjr=>qmjr), verbose )
            end
        end

    end
end


end #module
