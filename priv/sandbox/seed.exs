# Rebuilds the synthetic `sandbox` source database and writes every personal
# value it inserted to tmp/sandbox_pii.json, the ground truth for leak checks.
#
#     mix run priv/sandbox/seed.exs

defmodule Sandbox.Seed do
  @given_names ~w(Jan Anna Piotr Katarzyna Tomasz Małgorzata Krzysztof Agnieszka Paweł Zofia Grzegorz Ewa)
  @surnames ~w(Kowalski Nowak Wiśniewski Wójcik Kowalczyk Kamiński Lewandowski Zieliński Szymański Woźniak Dąbrowski Kozłowski)
  @streets ~w(Marszałkowska Piotrkowska Długa Floriańska Kwiatowa Lipowa Polna Słoneczna)
  @cities ~w(Warszawa Kraków Łódź Gdańsk Poznań Wrocław Lublin)
  @trades ["Usługi Remontowe", "Doradztwo IT", "Transport", "Studio Graficzne", "Hydraulika"]
  # People mentioned only in free text, never stored in a structured column.
  @outsiders ["Barbara Wróbel", "pani Basia Pawlak", "Jerzy Mazur", "Ola Sikora"]
  @uuid_columns [:id, :organization_id, :user_id, :buyer_id, :requisition_id, :bank_account_id, :record_id]

  def run do
    :rand.seed(:exsss, {20, 26, 10})
    {:ok, conn} = url() |> Ecto.Repo.Supervisor.parse_url() |> Postgrex.start_link()
    {:ok, pii} = Agent.start_link(fn -> MapSet.new() end)
    Process.put(:pii, pii)

    "priv/sandbox/schema.sql"
    |> File.read!()
    |> String.split(~r/;\s*$/m)
    |> Enum.map(&strip_comments/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&Postgrex.query!(conn, &1, []))

    orgs = for _ <- 1..3, do: insert_organization(conn)

    Enum.each(orgs, fn org ->
      for _ <- 1..3, do: insert_user(conn, org)
      counterparties = for _ <- 1..6, do: insert_counterparty(conn, org)
      Enum.each(counterparties, &insert_invoices(conn, org, &1))
      insert_bank(conn, org, counterparties)
    end)

    insert_failing_ksef_job(conn, hd(orgs))

    File.mkdir_p!("tmp")
    values = pii |> Agent.get(& &1) |> Enum.sort()
    File.write!("tmp/sandbox_pii.json", Jason.encode!(values, pretty: true))
    IO.puts("Seeded sandbox; #{length(values)} personal values in tmp/sandbox_pii.json")
  end

  defp url,
    do: System.get_env("SANDBOX_ADMIN_URL", "postgres://postgres:postgres@localhost:5455/sandbox")

  defp strip_comments(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "--"))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp insert_organization(conn) do
    name = "#{pick(@trades)} #{pick(@surnames)} Sp. z o.o."
    org = %{id: uuid(), name: track(name), nip: track(nip()), address: track(address())}

    insert(conn, "organizations", Map.put(org, :inserted_at, DateTime.utc_now()))
  end

  defp insert_user(conn, org) do
    {given, surname} = person()

    user =
      insert(conn, "users", %{
        id: uuid(),
        organization_id: org.id,
        email: track(email(given, surname)),
        name: track("#{given} #{surname}"),
        phone: track(phone()),
        bank_account_number: track(nrb()),
        hashed_password: track("$argon2id$v=19$m=65536,t=3,p=4$" <> random_b64(24)),
        inserted_at: DateTime.utc_now()
      })

    insert(conn, "user_identities", %{
      id: uuid(),
      user_id: user.id,
      strategy: "google",
      access_token: track("ya29." <> random_b64(30)),
      refresh_token: track("1//" <> random_b64(30))
    })
  end

  defp insert_counterparty(conn, org) do
    {given, surname} = person()
    sole_trader? = :rand.uniform() < 0.5

    display_name =
      if sole_trader?, do: "#{given} #{surname} #{pick(@trades)}", else: "#{surname} i Wspólnicy S.A."

    conn
    |> insert("counterparties", %{
      id: uuid(),
      organization_id: org.id,
      display_name: track(display_name),
      given_name: if(sole_trader?, do: track(given)),
      surname: if(sole_trader?, do: track(surname)),
      tax_id: track(nip()),
      pesel: if(sole_trader?, do: track(pesel())),
      email: track(email(given, surname)),
      phone: track(phone()),
      address: track(address()),
      description: "Kontakt: #{track("#{given} #{surname}")}, tel. #{track(phone())}. Płaci po terminie."
    })
    |> Map.merge(%{given: given, surname: surname})
  end

  defp insert_invoices(conn, org, counterparty) do
    for n <- 1..3 do
      insert(conn, "sales_invoices", %{
        id: uuid(),
        organization_id: org.id,
        buyer_id: counterparty.id,
        number: "FV/#{n}/10/2026",
        state: pick(~w(draft issued issued sent_to_ksef paid)),
        buyer_display_name: counterparty.display_name,
        buyer_tax_id: counterparty.tax_id,
        gross_total: Decimal.new("#{:rand.uniform(20_000)}.#{:rand.uniform(89) + 10}"),
        currency: "PLN",
        issue_date: Date.add(~D[2026-10-01], :rand.uniform(18)),
        internal_note:
          if(n == 1,
            do:
              "Rozmawiałem z #{track(genitive(counterparty))}, obiecał zapłacić do piątku. " <>
                "Sprawę przejęła #{track(pick(@outsiders))} z księgowości."
          ),
        ksef_number: if(n > 1, do: "#{org.nip}-20261015-#{random_hex(6)}-#{random_hex(1)}")
      })
    end
  end

  defp insert_bank(conn, org, counterparties) do
    requisition =
      insert(conn, "requisitions", %{
        id: uuid(),
        organization_id: org.id,
        status: pick(~w(accepted expired)),
        inserted_at: DateTime.utc_now()
      })

    account =
      insert(conn, "bank_accounts", %{
        id: uuid(),
        organization_id: org.id,
        requisition_id: requisition.id,
        iban: track("PL" <> nrb()),
        owner_name: org.name,
        institution_name: pick(["mBank", "PKO BP", "ING Bank Śląski"])
      })

    Enum.each(counterparties, fn cp ->
      insert(conn, "transactions", %{
        id: uuid(),
        bank_account_id: account.id,
        amount: Decimal.new("#{:rand.uniform(9_000)}.00"),
        booking_date: Date.add(~D[2026-10-01], :rand.uniform(18)),
        debtor_name: track("#{cp.given} #{cp.surname}"),
        debtor_account: track("PL" <> nrb()),
        creditor_name: org.name,
        creditor_account: account.iban,
        remittance_information_unstructured:
          "Przelew od #{track(genitive(cp))} za FV/1/10/2026"
      })
    end)

    failed? = requisition.status == "expired"

    insert(conn, "oban.oban_jobs", %{
      state: if(failed?, do: "retryable", else: "completed"),
      queue: "bank_data",
      worker: "AshOban.Workers.BankAccountSyncTransactions",
      args: %{"primary_key" => %{"id" => account.id}, "tenant" => org.id},
      errors:
        if(failed?,
          do: [
            %{
              "at" => "2026-10-18T12:00:03Z",
              "attempt" => 1,
              "error" => "** (RuntimeError) sync failed: :requisition_expired"
            }
          ],
          else: []
        ),
      attempt: 1,
      max_attempts: 5,
      inserted_at: DateTime.utc_now(),
      attempted_at: DateTime.utc_now()
    })

    insert(conn, "ash_events", %{
      resource: "BankAccount",
      record_id: account.id,
      action: "sync_transactions",
      data: %{"result" => if(failed?, do: "failed", else: "ok"), "owner_name" => org.name},
      occurred_at: DateTime.utc_now()
    })
  end

  # A buyer NIP with a trailing space fails validation; the error inspects the changeset.
  defp insert_failing_ksef_job(conn, org) do
    {given, surname} = person()
    bad_nip = track(nip()) <> " "
    buyer = track("#{given} #{surname}")
    buyer_email = track(email(given, surname))
    invoice_id = uuid()

    insert(conn, "sales_invoices", %{
      id: invoice_id,
      organization_id: org.id,
      number: "FV/99/10/2026",
      state: "issued",
      buyer_display_name: buyer,
      buyer_tax_id: bad_nip,
      gross_total: Decimal.new("1230.00"),
      currency: "PLN",
      issue_date: ~D[2026-10-17]
    })

    error = """
    ** (Ash.Error.Invalid) Invalid Error

    * Invalid value provided for buyer_tax_id: does not match KSeF pattern.

    Value: #{inspect(bad_nip)}

    #Ash.Changeset<attributes: %{buyer_display_name: #{inspect(buyer)}, buyer_tax_id: #{inspect(bad_nip)}, email: #{inspect(buyer_email)}}>
    """

    insert(conn, "oban.oban_jobs", %{
      state: "retryable",
      queue: "ksef_submissions",
      worker: "App.Ksef.Workers.SubmitWorker",
      args: %{
        "sales_invoice_id" => invoice_id,
        "organization_id" => org.id,
        "encryption_key" => track(random_b64(32))
      },
      errors: [%{"at" => "2026-10-18T09:12:44Z", "attempt" => 3, "error" => error}],
      attempt: 3,
      max_attempts: 20,
      inserted_at: DateTime.utc_now(),
      attempted_at: DateTime.utc_now()
    })
  end

  defp insert(conn, table, row) do
    columns = Map.keys(row)
    names = Enum.map_join(columns, ", ", &~s("#{&1}"))
    placeholders = Enum.map_join(1..length(columns), ", ", &"$#{&1}")
    values = Enum.map(columns, &encode(&1, Map.fetch!(row, &1)))
    Postgrex.query!(conn, "INSERT INTO #{table} (#{names}) VALUES (#{placeholders})", values)
    row
  end

  defp encode(column, value) when column in @uuid_columns and is_binary(value),
    do: Ecto.UUID.dump!(value)

  defp encode(_column, value), do: value

  defp track(nil), do: nil

  defp track(value) do
    Agent.update(Process.get(:pii), &MapSet.put(&1, value))
    value
  end

  # Declined name forms are personal data too, and exact value matching cannot see them.
  defp genitive(%{given: given, surname: surname}),
    do: "#{genitive_given(given)} #{genitive_surname(surname)}"

  defp genitive_given(name) do
    cond do
      String.ends_with?(name, ["ka", "ga"]) -> String.slice(name, 0..-2//1) <> "i"
      String.ends_with?(name, "a") -> String.slice(name, 0..-2//1) <> "y"
      String.ends_with?(name, "eł") -> String.slice(name, 0..-3//1) <> "ła"
      true -> name <> "a"
    end
  end

  defp genitive_surname(name) do
    if String.ends_with?(name, "ski"), do: String.slice(name, 0..-2//1) <> "iego", else: name <> "a"
  end

  defp person, do: {pick(@given_names), pick(@surnames)}

  defp email(given, surname) do
    local =
      "#{given}.#{surname}"
      |> String.downcase()
      |> String.replace("ł", "l")
      |> String.normalize(:nfd)
      |> String.replace(~r/[^a-z.]/u, "")

    "#{local}#{:rand.uniform(99)}@#{pick(~w(gmail.com wp.pl onet.pl firma.pl))}"
  end

  defp phone, do: "+48 #{digits(3)} #{digits(3)} #{digits(3)}"

  defp address,
    do: "ul. #{pick(@streets)} #{:rand.uniform(120)}, #{digits(2)}-#{digits(3)} #{pick(@cities)}"

  defp nip do
    base = for _ <- 1..9, do: :rand.uniform(10) - 1
    check = base |> weighted_sum([6, 5, 7, 2, 3, 4, 5, 6, 7]) |> rem(11)
    if check == 10, do: nip(), else: Enum.join(base ++ [check])
  end

  defp pesel do
    date = Date.add(~D[1950-01-01], :rand.uniform(18_000))
    yy = rem(date.year, 100)
    base = Enum.flat_map([yy, date.month, date.day], &[div(&1, 10), rem(&1, 10)])
    base = base ++ for(_ <- 1..4, do: :rand.uniform(10) - 1)
    sum = weighted_sum(base, [1, 3, 7, 9, 1, 3, 7, 9, 1, 3])
    Enum.join(base ++ [rem(10 - rem(sum, 10), 10)])
  end

  defp nrb do
    bban = "1140" <> digits(4) <> digits(16)
    check = 98 - rem(String.to_integer(bban <> "252100"), 97)
    String.pad_leading("#{check}", 2, "0") <> bban
  end

  defp weighted_sum(digits, weights),
    do: digits |> Enum.zip(weights) |> Enum.map(fn {d, w} -> d * w end) |> Enum.sum()

  defp digits(n), do: Enum.map_join(1..n, fn _ -> :rand.uniform(10) - 1 end)
  defp random_hex(n), do: n |> :crypto.strong_rand_bytes() |> Base.encode16()
  defp random_b64(n), do: n |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp pick(list), do: Enum.random(list)
  defp uuid, do: Ecto.UUID.generate()
end

Sandbox.Seed.run()
